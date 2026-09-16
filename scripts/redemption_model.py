"""Integer accounting model only; no RPC, transactions, AMM or Solidity execution."""

from dataclasses import dataclass
from fractions import Fraction
from pathlib import Path
import argparse
import json
import random
import unittest

WEI = 10**18
TOKEN_UNIT = 10**18


@dataclass(frozen=True)
class Vault:
    reserve: int
    supply: int

    def __post_init__(self):
        if self.reserve < 0 or self.supply < 0:
            raise ValueError("negative state")

    def quote(self, amount: int) -> int:
        if self.supply == 0 or not 0 < amount <= self.supply:
            raise ValueError("invalid burn amount")
        return amount * self.reserve // self.supply

    def redeem(self, amount: int, minimum: int = 1):
        payout = self.quote(amount)
        if minimum < 0 or payout == 0 or payout < minimum:
            raise ValueError("zero payout or minimum not met")
        return Vault(self.reserve - payout, self.supply - amount), payout

    def fund(self, amount: int):
        if amount <= 0 or self.supply == 0:
            raise ValueError("invalid funding")
        return Vault(self.reserve + amount, self.supply)


@dataclass(frozen=True)
class TimedPool:
    """Vault plus the fixed window: holders redeem before the deadline, the issuer sweeps after.

    `withdrawn` is an irreversible flag rather than a `reserve == 0` test, so ETH
    forced in after the sweep cannot re-open it.
    """

    vault: Vault
    deadline: int
    withdrawn: bool = False

    def redeem(self, now: int, amount: int, minimum: int = 1):
        if now >= self.deadline:
            raise ValueError("redemption window closed")
        after, payout = self.vault.redeem(amount, minimum)
        return TimedPool(after, self.deadline, self.withdrawn), payout

    def fund(self, now: int, amount: int):
        if now >= self.deadline:
            raise ValueError("no deposits after the deadline")
        return TimedPool(self.vault.fund(amount), self.deadline, self.withdrawn)

    def withdraw_residual(self, now: int):
        if now < self.deadline:
            raise ValueError("deadline not reached")
        if self.withdrawn:
            raise ValueError("residual already withdrawn")
        residual = self.vault.reserve
        return TimedPool(Vault(0, self.vault.supply), self.deadline, True), residual


def split_fees(amount: int, issuer_bps: int, platform_bps: int):
    """Splits a claimed fee into (reserve, issuer, platform).

    Issuer and platform round down; the reserve absorbs the remainder, so no wei
    is ever lost and rounding always favours the holders rather than the payees.
    """
    if amount < 0 or issuer_bps < 0 or platform_bps < 0 or issuer_bps + platform_bps > 10_000:
        raise ValueError("invalid split")
    issuer = amount * issuer_bps // 10_000
    platform = amount * platform_bps // 10_000
    return amount - issuer - platform, issuer, platform


def route_platform_slice(now: int, official_deadline: int) -> str:
    """The 5% slice has exactly one destination, fixed by an immutable timestamp."""
    return "official_vault" if now < official_deadline else "platform_address"


class AccountingChecks(unittest.TestCase):
    def test_example_and_new_income(self):
        start = Vault(100 * WEI, 1_000_000_000 * TOKEN_UNIT)
        for amount, eth in [(1_000_000, Fraction(1, 10)),
                            (10_000_000, Fraction(1)),
                            (100_000_000, Fraction(10))]:
            self.assertEqual(start.quote(amount * TOKEN_UNIT), eth * WEI)
        after, paid = start.redeem(100_000_000 * TOKEN_UNIT)
        self.assertEqual(paid, 10 * WEI)
        self.assertEqual(Fraction(after.reserve, after.supply),
                         Fraction(start.reserve, start.supply))
        funded = after.fund(9 * WEI)
        self.assertEqual(funded.quote(1_000_000 * TOKEN_UNIT), 11 * WEI // 100)

    def test_order_has_no_advantage_with_exact_division(self):
        for order in [(100, 200, 300), (300, 200, 100), (200, 100, 300)]:
            state = Vault(10_000 * WEI, 1_000 * TOKEN_UNIT)
            for amount in order:
                state, payout = state.redeem(amount * TOKEN_UNIT)
                self.assertEqual(payout, amount * 10 * WEI)
            self.assertEqual(state.reserve, 4_000 * WEI)

    def test_exhaustive_rounding_and_solvent_transitions(self):
        for reserve in range(1, 41):
            for supply in range(1, 41):
                state = Vault(reserve, supply)
                for amount in range(1, supply + 1):
                    payout = state.quote(amount)
                    fair = Fraction(amount * reserve, supply)
                    self.assertLessEqual(payout, fair)
                    self.assertLess(fair - payout, 1)
                    if payout == 0:
                        with self.assertRaises(ValueError):
                            state.redeem(amount)
                        continue
                    after, paid = state.redeem(amount)
                    self.assertEqual(after.reserve + paid, reserve)
                    self.assertGreaterEqual(after.reserve, 0)
                    if after.supply:
                        self.assertGreaterEqual(Fraction(after.reserve, after.supply),
                                                Fraction(reserve, supply))

    def test_splitting_cannot_increase_total_payout_without_inflows(self):
        for reserve in range(1, 26):
            for supply in range(2, 26):
                original = Vault(reserve, supply)
                for first in range(1, supply):
                    if original.quote(first) == 0:
                        continue
                    after, paid_first = original.redeem(first)
                    for second in range(1, after.supply + 1):
                        if after.quote(second) == 0:
                            continue
                        _, paid_second = after.redeem(second)
                        self.assertLessEqual(paid_first + paid_second,
                                             original.quote(first + second))

    def test_random_sequences_conserve_assets_and_unit_backing(self):
        rng = random.Random(20260907)
        for _ in range(10_000):
            state = Vault(rng.randint(1, 10**30), rng.randint(1, 10**32))
            cumulative_funding, cumulative_payout = state.reserve, 0
            for _ in range(20):
                if not state.supply:
                    break
                previous_ratio = Fraction(state.reserve, state.supply)
                if rng.randrange(3) == 0:
                    funding = rng.randint(1, 10**25)
                    state = state.fund(funding)
                    cumulative_funding += funding
                else:
                    amount = rng.randint(1, state.supply)
                    if state.quote(amount) == 0:
                        continue
                    state, payout = state.redeem(amount)
                    cumulative_payout += payout
                self.assertEqual(state.reserve + cumulative_payout, cumulative_funding)
                if state.supply:
                    self.assertGreaterEqual(Fraction(state.reserve, state.supply), previous_ratio)

    def test_full_redemption_in_abstract_fully_accessible_supply(self):
        state, paid = Vault(103, 17).redeem(17)
        self.assertEqual((state.reserve, state.supply, paid), (0, 0, 103))
        with self.assertRaises(ValueError):
            state.fund(1)

    def test_inaccessible_supply_leaves_backing_reserved(self):
        # No subtraction of permanently locked tokens in this conservative model.
        state, payout = Vault(100 * WEI, 1_000 * TOKEN_UNIT).redeem(400 * TOKEN_UNIT)
        self.assertEqual(payout, 40 * WEI)
        self.assertEqual((state.reserve, state.supply), (60 * WEI, 600 * TOKEN_UNIT))

    def test_pending_fees_not_claimable_until_funded(self):
        original = Vault(10 * WEI, 1_000 * TOKEN_UNIT)
        pending = 90 * WEI
        self.assertEqual(original.quote(100 * TOKEN_UNIT), WEI)
        funded = original.fund(pending)
        self.assertEqual(funded.quote(100 * TOKEN_UNIT), 10 * WEI)

    def test_invalid_or_zero_output_requests_do_not_change_model(self):
        original = Vault(1, 1_000)
        for amount in [-1, 0, 1, 999, 1_001]:
            with self.assertRaises(ValueError):
                original.redeem(amount)
            self.assertEqual(original, Vault(1, 1_000))
        with self.assertRaises(ValueError):
            Vault(0, 1_000).redeem(1_000)
        with self.assertRaises(ValueError):
            original.redeem(1_000, minimum=2)

    def test_large_product_requires_full_precision_muldiv_in_solidity(self):
        reserve, supply = 2**255 + 997, 2**250 + 123
        state = Vault(reserve, supply)
        amount = supply // 3
        self.assertGreater(amount * reserve, 2**256 - 1)
        after, payout = state.redeem(amount)
        self.assertLessEqual(payout, reserve)
        self.assertEqual(after.reserve + payout, reserve)
        self.assertLess(Fraction(amount * reserve, supply) - payout, 1)


class TerminalStateChecks(unittest.TestCase):
    """D-07: the deadline, the single-shot residual sweep, and their mutual exclusion."""

    DEADLINE = 1_000_000

    def pool(self, reserve=100 * WEI, supply=1_000_000 * TOKEN_UNIT):
        return TimedPool(Vault(reserve, supply), self.DEADLINE)

    def test_windows_are_adjacent_and_never_overlap(self):
        pool = self.pool()
        burn = 1_000 * TOKEN_UNIT
        for now in (0, self.DEADLINE - 1):
            pool.redeem(now, burn)
            with self.assertRaises(ValueError):
                pool.withdraw_residual(now)
        for now in (self.DEADLINE, self.DEADLINE + 1):
            with self.assertRaises(ValueError):
                pool.redeem(now, burn)
            pool.withdraw_residual(now)

    def test_sweep_pays_exact_residual_and_zeroes_reserve(self):
        pool = self.pool()
        after_burn, paid = pool.redeem(0, 250_000 * TOKEN_UNIT)
        final, residual = after_burn.withdraw_residual(self.DEADLINE)
        self.assertEqual(paid, 25 * WEI)
        self.assertEqual(residual, 75 * WEI)
        self.assertEqual(final.vault.reserve, 0)
        self.assertTrue(final.withdrawn)
        # Supply is untouched by the sweep: no tokens are burned by it.
        self.assertEqual(final.vault.supply, after_burn.vault.supply)

    def test_sweep_is_single_shot_and_guarded_by_the_flag_not_the_balance(self):
        final, _ = self.pool().withdraw_residual(self.DEADLINE)
        with self.assertRaises(ValueError):
            final.withdraw_residual(self.DEADLINE)
        # A non-zero reserve behind a set flag still refuses: ETH forced in
        # after the sweep must not re-open it.
        forced = TimedPool(Vault(5 * WEI, final.vault.supply), self.DEADLINE, withdrawn=True)
        with self.assertRaises(ValueError):
            forced.withdraw_residual(self.DEADLINE)

    def test_no_funding_after_the_deadline(self):
        pool = self.pool()
        pool.fund(self.DEADLINE - 1, WEI)
        for now in (self.DEADLINE, self.DEADLINE + 10**6):
            with self.assertRaises(ValueError):
                pool.fund(now, WEI)

    def test_rejected_calls_leave_state_unchanged(self):
        pool = self.pool()
        for call in (lambda: pool.redeem(self.DEADLINE, TOKEN_UNIT),
                     lambda: pool.withdraw_residual(0),
                     lambda: pool.fund(self.DEADLINE, WEI),
                     lambda: pool.redeem(0, 0)):
            with self.assertRaises(ValueError):
                call()
            self.assertEqual(pool, self.pool())

    def test_lifecycle_conserves_every_wei(self):
        rng = random.Random(20260907)
        for _ in range(2_000):
            pool = TimedPool(Vault(rng.randint(1, 10**24), rng.randint(1, 10**26)), self.DEADLINE)
            funded, paid_out = pool.vault.reserve, 0
            for _ in range(20):
                now = rng.randrange(self.DEADLINE)
                if not pool.vault.supply:
                    break
                if rng.randrange(3) == 0:
                    amount = rng.randint(1, 10**22)
                    pool = pool.fund(now, amount)
                    funded += amount
                else:
                    amount = rng.randint(1, pool.vault.supply)
                    if pool.vault.quote(amount) == 0:
                        continue
                    pool, payout = pool.redeem(now, amount)
                    paid_out += payout
            _, residual = pool.withdraw_residual(self.DEADLINE)
            # Nothing is created and nothing is stranded: every funded wei is
            # either paid to a burner or swept to the issuer.
            self.assertEqual(paid_out + residual, funded)


class DistributionChecks(unittest.TestCase):
    """The 85/10/5 split and the deterministic route of the platform slice."""

    THIRD_PARTY = (1_000, 500)   # issuer 10%, platform 5%
    OFFICIAL = (1_000, 0)        # issuer 10%, no self-tax
    OFFICIAL_DEADLINE = 2_000_000

    def test_split_never_loses_or_creates_a_wei(self):
        for bps in (self.THIRD_PARTY, self.OFFICIAL):
            for amount in list(range(0, 400)) + [10**18, 10**18 + 7, 3 * WEI + 1, 2**200 - 1]:
                reserve, issuer, platform = split_fees(amount, *bps)
                self.assertEqual(reserve + issuer + platform, amount)
                self.assertTrue(reserve >= 0 and issuer >= 0 and platform >= 0)

    def test_rounding_favours_the_pool_not_the_payees(self):
        for amount in range(1, 2_000):
            reserve, issuer, platform = split_fees(amount, *self.THIRD_PARTY)
            self.assertLessEqual(issuer, amount * 1_000 // 10_000)
            self.assertLessEqual(platform, amount * 500 // 10_000)
            self.assertGreaterEqual(reserve * 10_000, amount * 8_500)

    def test_official_token_has_no_third_slice(self):
        reserve, issuer, platform = split_fees(1_000 * WEI, *self.OFFICIAL)
        self.assertEqual(platform, 0)
        self.assertEqual((reserve, issuer), (900 * WEI, 100 * WEI))

    def test_platform_slice_has_exactly_one_destination(self):
        d = self.OFFICIAL_DEADLINE
        for now in (0, 1, d - 1):
            self.assertEqual(route_platform_slice(now, d), "official_vault")
        for now in (d, d + 1, d + 10**9):
            self.assertEqual(route_platform_slice(now, d), "platform_address")

    def test_official_pool_refuses_the_slice_once_expired(self):
        # A vault past its deadline must reject funding, which is exactly why the
        # route flips at the same timestamp: the two rules cannot disagree.
        pool = TimedPool(Vault(WEI, TOKEN_UNIT), self.OFFICIAL_DEADLINE)
        pool.fund(self.OFFICIAL_DEADLINE - 1, WEI)
        with self.assertRaises(ValueError):
            pool.fund(self.OFFICIAL_DEADLINE, WEI)
        self.assertEqual(route_platform_slice(self.OFFICIAL_DEADLINE, self.OFFICIAL_DEADLINE),
                         "platform_address")


def report():
    state = Vault(100 * WEI, 1_000_000_000 * TOKEN_UNIT)
    examples = []
    for tokens in (1_000_000, 10_000_000, 100_000_000):
        payout = state.quote(tokens * TOKEN_UNIT)
        examples.append({"burn_tokens": tokens, "payout_wei": str(payout),
                         "payout_eth": str(Fraction(payout, WEI))})
    return {
        "scope": "Integer accounting only, no deployed-contract or AMM verification",
        "denominator": "totalSupply before burn; includes locked and pooled tokens",
        "random_sequences": 10_000,
        "maximum_operations_per_sequence": 20,
        "seed": 20260907,
        "example_start": {"reserve_eth": 100, "supply_tokens": 1_000_000_000},
        "independent_quotes_at_example_start": examples,
        "distribution": {
            "third_party": "85% reserve / 10% issuer / 5% official pool",
            "official": "90% reserve / 10% issuer",
            "rounding": "issuer and platform round down; reserve absorbs the remainder",
            "platform_route": "now < OFFICIAL_DEADLINE -> official vault, else platform address",
        },
        "terminal_state": {
            "model": "TimedPool: redeem while now < deadline, issuer sweep while now >= deadline",
            "checked": ["adjacent non-overlapping windows", "sweep pays exact residual",
                        "single-shot sweep guarded by flag not balance",
                        "no funding after deadline", "rejected calls leave state unchanged",
                        "lifecycle conservation over 2,000 random sequences"],
            "lifecycle_sequences": 2_000,
        },
        "not_validated": ["bytecode", "allowances", "EVM rollback", "reentrancy", "fee sweep",
                          "graduation", "MEV profitability", "AMM liquidity", "gas cost",
                          "block.timestamp manipulation"],
    }


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--report", type=Path)
    args = parser.parse_args()
    loader = unittest.defaultTestLoader
    suite = unittest.TestSuite([loader.loadTestsFromTestCase(AccountingChecks),
                               loader.loadTestsFromTestCase(TerminalStateChecks),
                               loader.loadTestsFromTestCase(DistributionChecks)])
    result = unittest.TextTestRunner(verbosity=2).run(suite)
    if not result.wasSuccessful():
        raise SystemExit(1)
    if args.report:
        data = report()
        data["tests_passed"] = result.testsRun
        args.report.write_text(json.dumps(data, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
        print(f"Report written to {args.report}")
