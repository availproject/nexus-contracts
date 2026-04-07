// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {AvailEscrow} from "../src/AvailEscrow.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";

contract MockERC20 is ERC20 {
    constructor(string memory name, string memory symbol) ERC20(name, symbol) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract MockERC20Permit is ERC20Permit {
    constructor(string memory name, string memory symbol) ERC20(name, symbol) ERC20Permit(name) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract AvailEscrowTest is Test {
    AvailEscrow public escrow;
    MockERC20 public usdc;
    MockERC20 public cbbtc;
    MockERC20Permit public permitToken;

    address constant ETH_ADDRESS = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

    address owner = makeAddr("owner");
    address solver = makeAddr("solver");
    uint256 userPk;
    address user;

    function setUp() public {
        (user, userPk) = makeAddrAndKey("user");

        usdc = new MockERC20("USDC", "USDC");
        cbbtc = new MockERC20("cbBTC", "cbBTC");
        permitToken = new MockERC20Permit("PermitToken", "PT");

        AvailEscrow impl = new AvailEscrow();
        bytes memory initData = abi.encodeCall(AvailEscrow.initialize, (owner, 1 hours));
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        escrow = AvailEscrow(payable(address(proxy)));

        vm.deal(user, 100 ether);
        vm.deal(solver, 100 ether);
        usdc.mint(user, 100_000e6);
        usdc.mint(solver, 100_000e6);
        cbbtc.mint(user, 10e8);
        cbbtc.mint(solver, 10e8);
        permitToken.mint(user, 100_000e18);
        permitToken.mint(solver, 100_000e18);
    }

    // ──────────────────────────────────────────────────────────────────
    // Initialize
    // ──────────────────────────────────────────────────────────────────

    function test_initialize() public view {
        assertEq(escrow.owner(), owner);
        assertEq(escrow.globalUnlockTimeout(), 1 hours);
    }

    function test_initialize_revertsOnReinit() public {
        vm.expectRevert();
        escrow.initialize(owner, 1 hours);
    }

    // ──────────────────────────────────────────────────────────────────
    // Deposit
    // ──────────────────────────────────────────────────────────────────

    function test_deposit_eth() public {
        bytes32 id = keccak256("intent1");
        uint256 deadline = block.timestamp + 1 hours;

        vm.prank(user);
        escrow.deposit{value: 1 ether}(id, solver, ETH_ADDRESS, 1 ether, address(usdc), 2000e6, deadline, "");

        (
            bytes32 intentId,
            address intentUser,
            AvailEscrow.IntentStatus status,
            uint48 depositTimestamp,
            address intentSolver,
            uint48 intentDeadline,
            address tokenIn,
            uint256 amountIn,
            address tokenOut,
            uint256 amountOutMin
        ) = escrow.intents(id);

        assertEq(intentId, id);
        assertEq(intentUser, user);
        assertEq(uint8(status), uint8(AvailEscrow.IntentStatus.DEPOSITED));
        assertEq(depositTimestamp, block.timestamp);
        assertEq(intentSolver, solver);
        assertEq(intentDeadline, deadline);
        assertEq(tokenIn, ETH_ADDRESS);
        assertEq(amountIn, 1 ether);
        assertEq(tokenOut, address(usdc));
        assertEq(amountOutMin, 2000e6);
    }

    function test_deposit_erc20() public {
        bytes32 id = keccak256("intent2");
        uint256 deadline = block.timestamp + 1 hours;

        vm.startPrank(user);
        usdc.approve(address(escrow), 1000e6);
        escrow.deposit(id, solver, address(usdc), 1000e6, ETH_ADDRESS, 0.5 ether, deadline, "");
        vm.stopPrank();

        _assertStatus(id, AvailEscrow.IntentStatus.DEPOSITED);
        assertEq(usdc.balanceOf(address(escrow)), 1000e6);
    }

    function test_deposit_erc20_withPermit() public {
        bytes32 id = keccak256("permit_deposit");
        uint256 deadline = block.timestamp + 1 hours;
        uint256 amount = 500e18;

        bytes memory permit = _signPermit(userPk, address(permitToken), address(escrow), amount, deadline);

        vm.prank(user);
        escrow.deposit(id, solver, address(permitToken), amount, ETH_ADDRESS, 0.1 ether, deadline, permit);

        _assertStatus(id, AvailEscrow.IntentStatus.DEPOSITED);
        assertEq(permitToken.balanceOf(address(escrow)), amount);
    }

    function test_deposit_erc20_permitFrontrunGriefResistance() public {
        bytes32 id = keccak256("frontrun_permit");
        uint256 deadline = block.timestamp + 1 hours;
        uint256 amount = 500e18;

        bytes memory permit = _signPermit(userPk, address(permitToken), address(escrow), amount, deadline);

        // Frontrunner submits the permit directly on the token
        (uint256 permitDeadline, uint8 v, bytes32 r, bytes32 s) =
            abi.decode(permit, (uint256, uint8, bytes32, bytes32));
        ERC20Permit(address(permitToken)).permit(user, address(escrow), amount, permitDeadline, v, r, s);

        // Deposit still succeeds — try/catch absorbs the revert, allowance already set
        vm.prank(user);
        escrow.deposit(id, solver, address(permitToken), amount, ETH_ADDRESS, 0.1 ether, deadline, permit);

        _assertStatus(id, AvailEscrow.IntentStatus.DEPOSITED);
    }

    function test_deposit_revertsOnPermitWithEth() public {
        vm.prank(user);
        vm.expectRevert(AvailEscrow.PermitNotAllowedForEth.selector);
        escrow.deposit{value: 1 ether}(
            keccak256("eth_permit"), solver, ETH_ADDRESS, 1 ether, address(usdc), 2000e6, block.timestamp + 1 hours, "deadbeef"
        );
    }

    function test_deposit_revertsOnDuplicateId() public {
        bytes32 id = keccak256("dup");
        uint256 deadline = block.timestamp + 1 hours;

        vm.prank(user);
        escrow.deposit{value: 1 ether}(id, solver, ETH_ADDRESS, 1 ether, address(usdc), 2000e6, deadline, "");

        vm.prank(user);
        vm.expectRevert(AvailEscrow.IntentAlreadyExists.selector);
        escrow.deposit{value: 1 ether}(id, solver, ETH_ADDRESS, 1 ether, address(usdc), 2000e6, deadline, "");
    }

    function test_deposit_revertsOnSameAsset() public {
        vm.prank(user);
        vm.expectRevert(AvailEscrow.SameAsset.selector);
        escrow.deposit{value: 1 ether}(
            keccak256("same"), solver, ETH_ADDRESS, 1 ether, ETH_ADDRESS, 1 ether, block.timestamp + 1 hours, ""
        );
    }

    function test_deposit_revertsOnZeroAmount() public {
        vm.prank(user);
        vm.expectRevert(AvailEscrow.ZeroAmount.selector);
        escrow.deposit(keccak256("zero"), solver, ETH_ADDRESS, 0, address(usdc), 2000e6, block.timestamp + 1 hours, "");
    }

    function test_deposit_revertsOnZeroAmountOutMin() public {
        vm.prank(user);
        vm.expectRevert(AvailEscrow.ZeroAmount.selector);
        escrow.deposit{value: 1 ether}(
            keccak256("zero_out"), solver, ETH_ADDRESS, 1 ether, address(usdc), 0, block.timestamp + 1 hours, ""
        );
    }

    function test_deposit_revertsOnExpiredDeadline() public {
        vm.prank(user);
        vm.expectRevert(AvailEscrow.DeadlineInPast.selector);
        escrow.deposit{value: 1 ether}(
            keccak256("expired"), solver, ETH_ADDRESS, 1 ether, address(usdc), 2000e6, block.timestamp, ""
        );
    }

    function test_deposit_revertsOnDeadlineOverflow() public {
        vm.prank(user);
        vm.expectRevert(AvailEscrow.DeadlineOverflow.selector);
        escrow.deposit{value: 1 ether}(
            keccak256("overflow"), solver, ETH_ADDRESS, 1 ether, address(usdc), 2000e6, uint256(type(uint48).max) + 1, ""
        );
    }

    function test_deposit_revertsOnWrongMsgValue_ethTooLittle() public {
        vm.prank(user);
        vm.expectRevert(AvailEscrow.InvalidMsgValue.selector);
        escrow.deposit{value: 0.5 ether}(
            keccak256("wrong"), solver, ETH_ADDRESS, 1 ether, address(usdc), 2000e6, block.timestamp + 1 hours, ""
        );
    }

    function test_deposit_revertsOnMsgValueWithErc20() public {
        vm.startPrank(user);
        usdc.approve(address(escrow), 1000e6);
        vm.expectRevert(AvailEscrow.InvalidMsgValue.selector);
        escrow.deposit{value: 1 ether}(
            keccak256("erc20_val"), solver, address(usdc), 1000e6, ETH_ADDRESS, 0.5 ether, block.timestamp + 1 hours, ""
        );
        vm.stopPrank();
    }

    // ──────────────────────────────────────────────────────────────────
    // Settle
    // ──────────────────────────────────────────────────────────────────

    function test_settle_ethIn_erc20Out() public {
        bytes32 id = _depositEthForUsdc(1 ether, 2000e6);

        uint256 userUsdcBefore = usdc.balanceOf(user);
        uint256 solverEthBefore = solver.balance;

        vm.startPrank(solver);
        usdc.approve(address(escrow), 2000e6);
        escrow.settle(id, 2000e6);
        vm.stopPrank();

        assertEq(usdc.balanceOf(user), userUsdcBefore + 2000e6);
        assertEq(solver.balance, solverEthBefore + 1 ether);
        _assertStatus(id, AvailEscrow.IntentStatus.SETTLED);
    }

    function test_settle_erc20In_ethOut() public {
        bytes32 id = _depositUsdcForEth(1000e6, 0.5 ether);

        uint256 userEthBefore = user.balance;
        uint256 solverUsdcBefore = usdc.balanceOf(solver);

        vm.prank(solver);
        escrow.settle{value: 0.5 ether}(id, 0.5 ether);

        assertEq(user.balance, userEthBefore + 0.5 ether);
        assertEq(usdc.balanceOf(solver), solverUsdcBefore + 1000e6);
        _assertStatus(id, AvailEscrow.IntentStatus.SETTLED);
    }

    function test_settle_erc20In_erc20Out() public {
        bytes32 id = keccak256("erc20_erc20");

        vm.startPrank(user);
        usdc.approve(address(escrow), 1000e6);
        escrow.deposit(id, solver, address(usdc), 1000e6, address(cbbtc), 1e7, block.timestamp + 1 hours, "");
        vm.stopPrank();

        vm.startPrank(solver);
        cbbtc.approve(address(escrow), 1e7);
        escrow.settle(id, 1e7);
        vm.stopPrank();

        assertEq(cbbtc.balanceOf(user), 10e8 + 1e7);
        assertEq(usdc.balanceOf(solver), 100_000e6 + 1000e6);
    }

    function test_settle_revertsOnNotDeposited() public {
        vm.prank(solver);
        vm.expectRevert(AvailEscrow.IntentNotDeposited.selector);
        escrow.settle(keccak256("nonexistent"), 1000e6);
    }

    function test_settle_revertsOnWrongSolver() public {
        bytes32 id = _depositEthForUsdc(1 ether, 2000e6);
        vm.prank(makeAddr("other"));
        vm.expectRevert(AvailEscrow.NotDesignatedSolver.selector);
        escrow.settle(id, 2000e6);
    }

    function test_settle_revertsAfterDeadline() public {
        bytes32 id = _depositEthForUsdc(1 ether, 2000e6);
        vm.warp(block.timestamp + 2 hours);

        vm.startPrank(solver);
        usdc.approve(address(escrow), 2000e6);
        vm.expectRevert(AvailEscrow.DeadlineExpired.selector);
        escrow.settle(id, 2000e6);
        vm.stopPrank();
    }

    function test_settle_revertsOnSlippage() public {
        bytes32 id = _depositEthForUsdc(1 ether, 2000e6);

        vm.startPrank(solver);
        usdc.approve(address(escrow), 1999e6);
        vm.expectRevert(AvailEscrow.SlippageExceeded.selector);
        escrow.settle(id, 1999e6);
        vm.stopPrank();
    }

    function test_settle_revertsOnAlreadySettled() public {
        bytes32 id = _depositEthForUsdc(1 ether, 2000e6);

        vm.startPrank(solver);
        usdc.approve(address(escrow), 4000e6);
        escrow.settle(id, 2000e6);
        vm.expectRevert(AvailEscrow.IntentNotDeposited.selector);
        escrow.settle(id, 2000e6);
        vm.stopPrank();
    }

    function test_settle_revertsOnWrongMsgValueEthOut() public {
        bytes32 id = _depositUsdcForEth(1000e6, 0.5 ether);

        vm.prank(solver);
        vm.expectRevert(AvailEscrow.InvalidMsgValue.selector);
        escrow.settle{value: 0.3 ether}(id, 0.5 ether);
    }

    // ──────────────────────────────────────────────────────────────────
    // Unlock
    // ──────────────────────────────────────────────────────────────────

    function test_unlock_eth() public {
        bytes32 id = _depositEthForUsdc(1 ether, 2000e6);
        uint256 userEthBefore = user.balance;

        vm.prank(solver);
        escrow.unlock(id);

        assertEq(user.balance, userEthBefore + 1 ether);
        _assertStatus(id, AvailEscrow.IntentStatus.UNLOCKED);
    }

    function test_unlock_erc20() public {
        bytes32 id = _depositUsdcForEth(1000e6, 0.5 ether);
        uint256 userUsdcBefore = usdc.balanceOf(user);

        vm.prank(solver);
        escrow.unlock(id);

        assertEq(usdc.balanceOf(user), userUsdcBefore + 1000e6);
    }

    function test_unlock_revertsOnNotDeposited() public {
        vm.prank(solver);
        vm.expectRevert(AvailEscrow.IntentNotDeposited.selector);
        escrow.unlock(keccak256("nope"));
    }

    function test_unlock_revertsOnWrongSolver() public {
        bytes32 id = _depositEthForUsdc(1 ether, 2000e6);
        vm.prank(makeAddr("rando"));
        vm.expectRevert(AvailEscrow.NotDesignatedSolver.selector);
        escrow.unlock(id);
    }

    // ──────────────────────────────────────────────────────────────────
    // Emergency Unlock
    // ──────────────────────────────────────────────────────────────────

    function test_emergencyUnlock_afterGlobalTimeout() public {
        bytes32 id = _depositEthForUsdc(1 ether, 2000e6);
        uint256 userEthBefore = user.balance;

        vm.warp(block.timestamp + 1 hours + 1);
        escrow.emergencyUnlock(id);

        assertEq(user.balance, userEthBefore + 1 ether);
    }

    function test_emergencyUnlock_afterDeadline() public {
        bytes32 id = keccak256("short_deadline");
        uint256 deadline = block.timestamp + 10 minutes;

        vm.prank(user);
        escrow.deposit{value: 1 ether}(id, solver, ETH_ADDRESS, 1 ether, address(usdc), 2000e6, deadline, "");

        vm.warp(deadline + 1);
        escrow.emergencyUnlock(id);

        _assertStatus(id, AvailEscrow.IntentStatus.UNLOCKED);
    }

    function test_emergencyUnlock_revertsBeforeTimeout() public {
        bytes32 id = _depositEthForUsdc(1 ether, 2000e6);

        vm.expectRevert(AvailEscrow.UnlockNotReady.selector);
        escrow.emergencyUnlock(id);
    }

    function test_emergencyUnlock_callableByAnyone() public {
        bytes32 id = _depositEthForUsdc(1 ether, 2000e6);
        vm.warp(block.timestamp + 1 hours + 1);

        vm.prank(makeAddr("random"));
        escrow.emergencyUnlock(id);

        _assertStatus(id, AvailEscrow.IntentStatus.UNLOCKED);
    }

    // ──────────────────────────────────────────────────────────────────
    // Admin: timeout
    // ──────────────────────────────────────────────────────────────────

    function test_setGlobalUnlockTimeout() public {
        vm.prank(owner);
        escrow.setGlobalUnlockTimeout(2 hours);
        assertEq(escrow.globalUnlockTimeout(), 2 hours);
    }

    function test_setGlobalUnlockTimeout_revertsOutOfRange() public {
        vm.startPrank(owner);
        vm.expectRevert(AvailEscrow.TimeoutOutOfRange.selector);
        escrow.setGlobalUnlockTimeout(10 minutes);

        vm.expectRevert(AvailEscrow.TimeoutOutOfRange.selector);
        escrow.setGlobalUnlockTimeout(25 hours);
        vm.stopPrank();
    }

    // ──────────────────────────────────────────────────────────────────
    // Admin: ownership
    // ──────────────────────────────────────────────────────────────────

    function test_transferOwnership() public {
        address newOwner = makeAddr("newOwner");
        vm.prank(owner);
        escrow.transferOwnership(newOwner);
        assertEq(escrow.owner(), newOwner);
    }

    function test_transferOwnership_revertsOnZero() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(bytes4(keccak256("OwnableInvalidOwner(address)")), address(0)));
        escrow.transferOwnership(address(0));
    }

    // ──────────────────────────────────────────────────────────────────
    // Helpers
    // ──────────────────────────────────────────────────────────────────

    function _assertStatus(bytes32 id, AvailEscrow.IntentStatus expected) internal view {
        (, , AvailEscrow.IntentStatus status, , , , , , ,) = escrow.intents(id);
        assertEq(uint8(status), uint8(expected));
    }

    function _depositEthForUsdc(uint256 amountIn, uint256 amountOutMin) internal returns (bytes32 id) {
        id = keccak256(abi.encodePacked(amountIn, amountOutMin, block.timestamp));
        vm.prank(user);
        escrow.deposit{value: amountIn}(id, solver, ETH_ADDRESS, amountIn, address(usdc), amountOutMin, block.timestamp + 1 hours, "");
    }

    function _depositUsdcForEth(uint256 amountIn, uint256 amountOutMin) internal returns (bytes32 id) {
        id = keccak256(abi.encodePacked(amountIn, amountOutMin, block.timestamp));
        vm.startPrank(user);
        usdc.approve(address(escrow), amountIn);
        escrow.deposit(id, solver, address(usdc), amountIn, ETH_ADDRESS, amountOutMin, block.timestamp + 1 hours, "");
        vm.stopPrank();
    }

    function _signPermit(uint256 pk, address token, address spender, uint256 amount, uint256 deadline)
        internal
        view
        returns (bytes memory)
    {
        address signer = vm.addr(pk);
        uint256 nonce = ERC20Permit(token).nonces(signer);

        bytes32 structHash = keccak256(
            abi.encode(
                keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"),
                signer,
                spender,
                amount,
                nonce,
                deadline
            )
        );

        bytes32 domainSeparator = ERC20Permit(token).DOMAIN_SEPARATOR();
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encode(deadline, v, r, s);
    }
}
