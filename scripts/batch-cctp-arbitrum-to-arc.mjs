#!/usr/bin/env node
/**
 * Batch bridge native USDC from Arbitrum to Arc through Circle CCTP V2.
 *
 * Default mode only validates the input and prints a live fee quote.  Add
 * --execute to send the required ERC-20 approval and one CCTP burn per row.
 * Circle's Forwarding Service mints each transfer on Arc, so the recipient
 * does not need any existing Arc balance to receive it.
 *
 * Usage:
 *   node scripts/batch-cctp-arbitrum-to-arc.mjs transfers.json
 *   node scripts/batch-cctp-arbitrum-to-arc.mjs transfers.json --execute
 */

import fs from "node:fs";
import {
  Contract,
  JsonRpcProvider,
  Wallet,
  formatEther,
  formatUnits,
  getAddress,
  parseUnits,
  zeroPadValue,
} from "ethers";

const ARBITRUM_RPC = "https://arb1.arbitrum.io/rpc";
const ARC_RPC = "https://rpc.mainnet.arc.io";
const CCTP_FEE_API = "https://iris-api.circle.com/v2/burn/USDC/fees/3/26?forward=true";
const ARBITRUM_CHAIN_ID = 42161n;
const ARC_CHAIN_ID = 5042n;
const ARBITRUM_DOMAIN = 3;
const ARC_DOMAIN = 26;
const USDC = "0xaf88d065e77c8cC2239327C5EDb3A432268e5831";
const TOKEN_MESSENGER = "0x28b5a0e9C621a5BadaA536219b3a228C8168cf5d";
const FORWARD_HOOK = "0x636374702d666f72776172640000000000000000000000000000000000000000";
const ZERO_BYTES32 = `0x${"00".repeat(32)}`;

const USDC_ABI = [
  "function balanceOf(address) view returns (uint256)",
  "function allowance(address,address) view returns (uint256)",
  "function approve(address,uint256) returns (bool)",
];
const MESSENGER_ABI = [
  "function remoteTokenMessengers(uint32) view returns (bytes32)",
  "function depositForBurnWithHook(uint256,uint32,bytes32,address,bytes32,uint256,uint32,bytes)",
];

function fail(message) {
  throw new Error(message);
}

function loadPrivateKey() {
  const env = fs.readFileSync(".env", "utf8");
  const value = env.match(/^PRIVATE_KEY\s*=\s*([^\r\n#]+)/m)?.[1]
    ?.trim()
    .replace(/^["']|["']$/g, "");
  if (!value) fail("Missing PRIVATE_KEY in .env");
  return value.startsWith("0x") ? value : `0x${value}`;
}

function ceilDiv(value, divisor) {
  return (value + divisor - 1n) / divisor;
}

function parseDecimal(value, decimals) {
  const text = String(value);
  if (!/^\d+(?:\.\d+)?$/.test(text)) fail(`Invalid decimal: ${text}`);
  const [whole, fractional = ""] = text.split(".");
  if (fractional.length > decimals) fail(`Too many decimal places: ${text}`);
  return BigInt(whole + fractional.padEnd(decimals, "0"));
}

function readBatch(path) {
  const parsed = JSON.parse(fs.readFileSync(path, "utf8"));
  const config = Array.isArray(parsed) ? { transfers: parsed } : parsed;
  if (!Array.isArray(config.transfers) || config.transfers.length === 0) {
    fail("Input needs a non-empty transfers array");
  }
  if (config.transfers.length > 100) fail("Maximum 100 transfers per run");
  const feeBufferBps = config.feeBufferBps ?? 250;
  if (!Number.isInteger(feeBufferBps) || feeBufferBps < 0 || feeBufferBps > 1_000) {
    fail("feeBufferBps must be an integer from 0 to 1000");
  }
  const transfers = config.transfers.map((row, index) => {
    if (!row || typeof row !== "object") fail(`Row ${index + 1} is invalid`);
    let address;
    try {
      address = getAddress(row.address);
    } catch {
      fail(`Row ${index + 1} has an invalid address`);
    }
    let amount;
    try {
      amount = parseUnits(String(row.amount), 6);
    } catch {
      fail(`Row ${index + 1} has an invalid USDC amount`);
    }
    if (amount <= 0n) fail(`Row ${index + 1} amount must be positive`);
    return { address, amount };
  });
  return { feeBufferBps, transfers };
}

async function getFeeQuote() {
  const response = await fetch(CCTP_FEE_API);
  if (!response.ok) fail(`Circle fee API failed: HTTP ${response.status}`);
  const quotes = await response.json();
  const fast = quotes.find((quote) => quote.finalityThreshold === 1000);
  if (!fast?.forwardFee?.high || fast.minimumFee === undefined) {
    fail("Circle fee API did not return a Fast + Forwarding quote");
  }
  return {
    finalityThreshold: 1000,
    forwardFee: BigInt(fast.forwardFee.high),
    minimumFeeBpsHundredths: parseDecimal(fast.minimumFee, 2),
  };
}

function maxFeeFor(amount, quote, bufferBps) {
  // Circle expresses minimumFee in basis points; it may contain hundredths of a bp.
  const protocolFee = ceilDiv(amount * quote.minimumFeeBpsHundredths, 1_000_000n);
  const baseFee = quote.forwardFee + protocolFee;
  return ceilDiv(baseFee * BigInt(10_000 + bufferBps), 10_000n);
}

async function waitForArcCredit(arc, recipient, expectedIncrease, previousBalance) {
  for (let attempt = 0; attempt < 15; attempt += 1) {
    const current = await arc.getBalance(recipient);
    if (current >= previousBalance + expectedIncrease * 1_000_000_000_000n) return current;
    await new Promise((resolve) => setTimeout(resolve, 4_000));
  }
  return null;
}

const args = process.argv.slice(2);
const inputPath = args.find((arg) => !arg.startsWith("--"));
const execute = args.includes("--execute");
if (!inputPath || args.some((arg) => ![inputPath, "--execute"].includes(arg))) {
  console.error("Usage: node scripts/batch-cctp-arbitrum-to-arc.mjs <transfers.json> [--execute]");
  process.exit(1);
}

const batch = readBatch(inputPath);
const arb = new JsonRpcProvider(ARBITRUM_RPC);
const arc = new JsonRpcProvider(ARC_RPC);
try {
  const [arbNetwork, arcNetwork, quote] = await Promise.all([
    arb.getNetwork(),
    arc.getNetwork(),
    getFeeQuote(),
  ]);
  if (arbNetwork.chainId !== ARBITRUM_CHAIN_ID) fail("Arbitrum RPC is on the wrong chain");
  if (arcNetwork.chainId !== ARC_CHAIN_ID) fail("Arc RPC is on the wrong chain");

  const privateKey = loadPrivateKey();
  const signer = new Wallet(privateKey, arb);
  const usdc = new Contract(USDC, USDC_ABI, signer);
  const messenger = new Contract(TOKEN_MESSENGER, MESSENGER_ABI, signer);
  const remoteMessenger = await messenger.remoteTokenMessengers(ARC_DOMAIN);
  if (remoteMessenger.toLowerCase() !== zeroPadValue(TOKEN_MESSENGER, 32).toLowerCase()) {
    fail("CCTP remote messenger check failed for Arc");
  }

  const planned = batch.transfers.map((transfer, index) => {
    const maxFee = maxFeeFor(transfer.amount, quote, batch.feeBufferBps);
    if (transfer.amount <= maxFee) fail(`Row ${index + 1} amount is below its bridge fee`);
    return { ...transfer, maxFee, expectedArcUSDC: transfer.amount - maxFee };
  });
  const total = planned.reduce((sum, transfer) => sum + transfer.amount, 0n);
  const [sourceUSDC, sourceETH] = await Promise.all([
    usdc.balanceOf(signer.address),
    arb.getBalance(signer.address),
  ]);
  if (sourceUSDC < total) fail(`Insufficient USDC: have ${formatUnits(sourceUSDC, 6)}, need ${formatUnits(total, 6)}`);

  console.table(planned.map((transfer, index) => ({
    row: index + 1,
    recipient: transfer.address,
    sentUSDC: formatUnits(transfer.amount, 6),
    maxFeeUSDC: formatUnits(transfer.maxFee, 6),
    expectedArcUSDC: formatUnits(transfer.expectedArcUSDC, 6),
  })));
  console.log(JSON.stringify({
    mode: execute ? "EXECUTE" : "DRY_RUN",
    sender: signer.address,
    sourceUSDC: formatUnits(sourceUSDC, 6),
    sourceETHForGas: formatEther(sourceETH),
    totalUSDC: formatUnits(total, 6),
    forwardFeeUSDC: formatUnits(quote.forwardFee, 6),
    protocolFeeBps: Number(quote.minimumFeeBpsHundredths) / 100,
    feeBufferBps: batch.feeBufferBps,
  }, null, 2));
  if (!execute) {
    console.log("Dry run complete. Add --execute to send this batch.");
    process.exit(0);
  }

  const allowance = await usdc.allowance(signer.address, TOKEN_MESSENGER);
  if (allowance < total) {
    const approval = await usdc.approve(TOKEN_MESSENGER, total);
    const receipt = await approval.wait();
    if (receipt.status !== 1) fail("USDC approval failed");
    console.log(`Approved ${formatUnits(total, 6)} USDC: ${approval.hash}`);
  }

  for (const [index, transfer] of planned.entries()) {
    const beforeArcBalance = await arc.getBalance(transfer.address);
    const callArgs = [
      transfer.amount,
      ARC_DOMAIN,
      zeroPadValue(transfer.address, 32),
      USDC,
      ZERO_BYTES32,
      transfer.maxFee,
      quote.finalityThreshold,
      FORWARD_HOOK,
    ];
    const data = messenger.interface.encodeFunctionData("depositForBurnWithHook", callArgs);
    await arb.call({ from: signer.address, to: TOKEN_MESSENGER, data });
    const gas = await arb.estimateGas({ from: signer.address, to: TOKEN_MESSENGER, data });
    const tx = await signer.sendTransaction({
      to: TOKEN_MESSENGER,
      data,
      gasLimit: ceilDiv(gas * 120n, 100n),
    });
    const receipt = await tx.wait();
    if (receipt.status !== 1) fail(`Row ${index + 1} burn failed: ${tx.hash}`);
    const arcBalance = await waitForArcCredit(arc, transfer.address, transfer.expectedArcUSDC, beforeArcBalance);
    console.log(JSON.stringify({
      row: index + 1,
      recipient: transfer.address,
      burnTx: tx.hash,
      burnBlock: receipt.blockNumber,
      gasUsed: receipt.gasUsed.toString(),
      arcDelivered: arcBalance ? formatEther(arcBalance - beforeArcBalance) : "pending",
    }));
  }
} finally {
  arb.destroy();
  arc.destroy();
}
