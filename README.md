# Morpheus BuildersV4 — Subnet Admin Permanent Freeze PoC

Foundry proof of concept for a Morpheus bug bounty report (mor.org/bug-bounty).

**Finding:** any subnet admin of BuildersV4
(`0x42BB446eAE6dca7723a9eBdb81EA88aFe77eF4B9` on Base) can permanently freeze
all stakers' MOR in their subnet by raising `withdrawLockPeriodAfterDeposit`
retroactively via `editSubnet()`. The lock is read live at withdraw time, so
deposits made under the old lock freeze forever. The admin then keeps
harvesting yield from the frozen stake. Subnet admin is a permissionless role
(anyone creates a subnet for free); the attacker needs no protocol privilege.

## Run

```shell
forge test
```

One command, from a clean clone, no setup beyond the RPC URL. The test forks
Base at pinned block **58252712** (`vm.createSelectFork("base", ...)`).

Requires Foundry (forge). No dependencies — the test file is self-contained
(no forge-std).

## Tests (5 passing)

- `testFreezeCore` — victim stakes 1,000 MOR, admin raises the lock to
  2^127 s, victim's 999 MOR is frozen forever (withdraw reverts even after
  +1,000 years); attacker cannot steal the principal.
- `testMaxLockPanicsOnWithdraw` — lock at `type(uint128).max` panics `0x11`
  on withdraw; same permanent freeze.
- `testFrozenStakeKeepsPayingAdmin` — the frozen stake keeps accruing
  rewards and the admin harvests them (~22 MOR / 30 days from 1,000 MOR).
- `testMinimalDepositRaiseDoesNotFreeze` — control: raising `minimalDeposit`
  does NOT freeze; only the withdraw lock is the vector.
- `testClaimPaysRealRewards` — control: reward/claim accounting itself is
  sound (100,000 MOR / 30 days → 2,220 MOR claimed).

## Impact

- PoC: 999 MOR frozen ≈ **$738** at $0.738383/MOR (2026-11-16).
- Live exposure: all BuildersV4 deposits, **2,978,375 MOR ≈ $2.2M** — every
  subnet admin holds this power over their subnet's stakers.
