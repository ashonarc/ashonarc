#!/usr/bin/env node
/**
 * Batch bridge Arc native USDC to Arbitrum native USDC with Circle CCTP V2.
 *
 * Default mode validates and quotes only. Add --execute to broadcast an exact
 * USDC approval plus one CCTP burn per row. Circle's Forwarding Service sends
 * the Arbitrum mint transaction, so each recipient needs no ETH for delivery.
 *
 * Usage:
 *   node scripts/batch-cctp-arc-to-arbitrum.mjs transfers.json
 *   node scripts/batch-cctp-arc-to-arbitrum.mjs transfers.json --execute
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

const ARC_RPC = "https://rpc.mainnet.arc.io";
const ARBITRUM_RPC = "https://arb1.arbitrum.io/rpc";
const CCTP_FEE_API = "https://iris-api.circle.com/v2/burn/USDC/fees/26/3?forward=true";
const ARC_CHAIN_ID = 5042n;
const ARBITRUM_CHAIN_ID = 42161n;
const ARBITRUM_DOMAIN = 3;
const ARC_DOMAIN = 26;
const ARC_USDC = "0x3600000000000000000000000000000000000000";
const ARBITRUM_USDC = "0xaf88d065e77c8cC2239327C5EDb3A432268e5831";
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

function ceilDiv(value, divisor) {
  return (value + divisor - 1n) / divisor;
}

function loadPrivateKey() {
  const env = fs.readFileSync(".env", "utf8");
  const value = env.match(/^PRIVATE_KEY\s*=\s*([^\r\n#]+)/m)?.[1]
    ?.trim()
    .replace(/^["']|["']$/g, "");
  if (!value) fail("Missing PRIVATE_KEY in .env");
  return value.startsWith("0x") ? value : `0x${value}`;
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
  // Arc has no CCTP Fast Transfer source route. 2000 is the Standard transfer
  // finality threshold, which has a zero protocol fee on this route.
  const standard = quotes.find((quote) => quote.finalityThreshold === 2000);
  if (!standard?.forwardFee?.high || standard.minimumFee === undefined) {
    fail("Circle fee API did not return a Standard + Forwarding quote");
  }
  return {
    finalityThreshold: 2000,
    forwardFee: BigInt(standard.forwardFee.high),
    minimumFeeBpsHundredths: parseDecimal(standard.minimumFee, 2),
  };
}

function maxFeeFor(amount, quote, bufferBps) {
  const protocolFee = ceilDiv(amount * quote.minimumFeeBpsHundredths, 1_000_000n);
  const baseFee = quote.forwardFee + protocolFee;
  return ceilDiv(baseFee * BigInt(10_000 + bufferBps), 10_000n);
}

async function waitForArbitrumCredit(usdc, recipient, expectedIncrease, previousBalance) {
  for (let attempt = 0; attempt < 15; attempt += 1) {
    const current = await usdc.balanceOf(recipient);
    if (current >= previousBalance + expectedIncrease) return current;
    await new Promise((resolve) => setTimeout(resolve, 4_000));
  }
  return null;
}

const args = process.argv.slice(2);
const inputPath = args.find((arg) => !arg.startsWith("--"));
const execute = args.includes("--execute");
if (!inputPath || args.some((arg) => ![inputPath, "--execute"].includes(arg))) {
  console.error("Usage: node scripts/batch-cctp-arc-to-arbitrum.mjs <transfers.json> [--execute]");
  process.exit(1);
}

const batch = readBatch(inputPath);
const arc = new JsonRpcProvider(ARC_RPC);
const arbitrum = new JsonRpcProvider(ARBITRUM_RPC);
try {
  const [arcNetwork, arbitrumNetwork, quote] = await Promise.all([
    arc.getNetwork(),
    arbitrum.getNetwork(),
    getFeeQuote(),
  ]);
  if (arcNetwork.chainId !== ARC_CHAIN_ID) fail("Arc RPC is on the wrong chain");
  if (arbitrumNetwork.chainId !== ARBITRUM_CHAIN_ID) fail("Arbitrum RPC is on the wrong chain");

  const signer = new Wallet(loadPrivateKey(), arc);
  const arcUSDC = new Contract(ARC_USDC, USDC_ABI, signer);
  const messenger = new Contract(TOKEN_MESSENGER, MESSENGER_ABI, signer);
  const arbitrumUSDC = new Contract(ARBITRUM_USDC, USDC_ABI, arbitrum);
  const remoteMessenger = await messenger.remoteTokenMessengers(ARBITRUM_DOMAIN);
  if (remoteMessenger.toLowerCase() !== zeroPadValue(TOKEN_MESSENGER, 32).toLowerCase()) {
    fail("CCTP remote messenger check failed for Arbitrum");
  }

  const planned = batch.transfers.map((transfer, index) => {
    const maxFee = maxFeeFor(transfer.amount, quote, batch.feeBufferBps);
    if (transfer.amount <= maxFee) fail(`Row ${index + 1} amount is below its bridge fee`);
    return { ...transfer, maxFee, expectedArbitrumUSDC: transfer.amount - maxFee };
  });
  const total = planned.reduce((sum, transfer) => sum + transfer.amount, 0n);
  const [sourceUSDC, nativeGasUSDC] = await Promise.all([
    arcUSDC.balanceOf(signer.address),
    arc.getBalance(signer.address),
  ]);
  if (sourceUSDC < total) fail(`Insufficient USDC: have ${formatUnits(sourceUSDC, 6)}, need ${formatUnits(total, 6)}`);

  console.table(planned.map((transfer, index) => ({
    row: index + 1,
    recipient: transfer.address,
    sentUSDC: formatUnits(transfer.amount, 6),
    maxFeeUSDC: formatUnits(transfer.maxFee, 6),
    expectedArbitrumUSDC: formatUnits(transfer.expectedArbitrumUSDC, 6),
  })));
  console.log(JSON.stringify({
    mode: execute ? "EXECUTE" : "DRY_RUN",
    sender: signer.address,
    sourceArcUSDC: formatUnits(sourceUSDC, 6),
    sourceNativeGasUSDC: formatEther(nativeGasUSDC),
    totalUSDC: formatUnits(total, 6),
    forwardFeeUSDC: formatUnits(quote.forwardFee, 6),
    protocolFeeBps: Number(quote.minimumFeeBpsHundredths) / 100,
    feeBufferBps: batch.feeBufferBps,
  }, null, 2));
  if (!execute) {
    console.log("Dry run complete. Add --execute to send this batch.");
    process.exit(0);
  }

  const allowance = await arcUSDC.allowance(signer.address, TOKEN_MESSENGER);
  if (allowance < total) {
    const approval = await arcUSDC.approve(TOKEN_MESSENGER, total);
    const receipt = await approval.wait();
    if (receipt.status !== 1) fail("USDC approval failed");
    console.log(`Approved ${formatUnits(total, 6)} USDC: ${approval.hash}`);
  }

  for (const [index, transfer] of planned.entries()) {
    const beforeArbitrumBalance = await arbitrumUSDC.balanceOf(transfer.address);
    const callArgs = [
      transfer.amount,
      ARBITRUM_DOMAIN,
      zeroPadValue(transfer.address, 32),
      ARC_USDC,
      ZERO_BYTES32,
      transfer.maxFee,
      quote.finalityThreshold,
      FORWARD_HOOK,
    ];
    const data = messenger.interface.encodeFunctionData("depositForBurnWithHook", callArgs);
    await arc.call({ from: signer.address, to: TOKEN_MESSENGER, data });
    const gas = await arc.estimateGas({ from: signer.address, to: TOKEN_MESSENGER, data });
    const tx = await signer.sendTransaction({
      to: TOKEN_MESSENGER,
      data,
      gasLimit: ceilDiv(gas * 120n, 100n),
    });
    const receipt = await tx.wait();
    if (receipt.status !== 1) fail(`Row ${index + 1} burn failed: ${tx.hash}`);
    const arbitrumBalance = await waitForArbitrumCredit(
      arbitrumUSDC,
      transfer.address,
      transfer.expectedArbitrumUSDC,
      beforeArbitrumBalance,
    );
    console.log(JSON.stringify({
      row: index + 1,
      recipient: transfer.address,
      burnTx: tx.hash,
      burnBlock: receipt.blockNumber,
      gasUsed: receipt.gasUsed.toString(),
      arbitrumDelivered: arbitrumBalance
        ? formatUnits(arbitrumBalance - beforeArbitrumBalance, 6)
        : "pending",
    }));
  }
} finally {
  arc.destroy();
  arbitrum.destroy();
}
