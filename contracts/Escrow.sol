// SPDX-License-Identifier: MIT
//
// ─────────────────────────────────────────────────────────────────────────────
//  TESTBED — non-custodial escrow for a marketplace (TRON network, USDT TRC-20)
// ─────────────────────────────────────────────────────────────────────────────
//  This is NOT production code: it exists to MEASURE, on Tron's testnet (Nile),
//  what each escrow option actually costs, and to decide with numbers instead
//  of intuition. See README.md for the measured results.
//
//  HARD INVARIANT (a legal requirement, encoded as a design constraint): a
//  buyer's money can only end up at the SELLER or back at the BUYER. The fee
//  goes to a FIXED wallet declared at deployment. There is no general
//  withdrawal function of any kind.
//
//  Both options under comparison are implemented:
//    · EscrowFactory  (option A) — one address per order, derived via CREATE2.
//    · SingleEscrow   (option B) — one contract shared by all orders.
//
//  IMPORTANT (TVM compatibility): compile with evmVersion "istanbul" or
//  "paris". The PUSH0 opcode that solc emits from 0.8.20 onwards is NOT
//  supported by Tron's TVM; that is why 0.8.19 is pinned.
// ─────────────────────────────────────────────────────────────────────────────
pragma solidity 0.8.19;

interface ITRC20 {
    function transfer(address to, uint256 value) external returns (bool);
    function balanceOf(address who) external view returns (uint256);
}

/// A transfer that does NOT trust the token's return value — it verifies the
/// EFFECT instead.
///
/// USDT violates the TRC-20/ERC-20 standard in what `transfer` returns. The
/// usual pattern (OpenZeppelin's SafeERC20) accepts "no return" or "returns
/// true":
///
///     require(ok && (data.length == 0 || abi.decode(data, (bool))));
///
/// This contract started with that pattern, and it REVERTED — measured on the
/// Nile testnet: the test USDT moves the money correctly but returns 32 zero
/// bytes, i.e. `false`. Trusting the return value would have made every order
/// impossible to settle, in a token-dependent way.
///
/// So the recipient's balance is checked before and after: whatever the token
/// claims, what matters is that the money arrived. It costs two extra balance
/// reads; in exchange it works with any token, including ones that lie.
library SafeTransfer {
    function send(address token, address to, uint256 amount) internal {
        if (amount == 0) return;
        uint256 before = ITRC20(token).balanceOf(to);
        (bool ok, ) = token.call(
            abi.encodeWithSelector(ITRC20.transfer.selector, to, amount)
        );
        require(ok, "token call failed");
        require(ITRC20(token).balanceOf(to) >= before + amount, "token did not deliver");
    }
}

// ═════════════════════════════════════════════════════════════════════════════
//  OPTION A — one address per order
// ═════════════════════════════════════════════════════════════════════════════
//
//  How it works:
//    1. The backend computes `addressFor(orderId, buyer, seller)` — nothing
//       exists on-chain yet, so this costs ZERO.
//    2. The buyer sends USDT to that address from anywhere (including an
//       exchange).
//    3. The backend calls `resolve(...)`, which deploys an EPHEMERAL contract
//       there: it distributes the funds inside its own constructor and leaves
//       no persistent code.
//
//  WHY THE SALT BINDS BUYER AND SELLER — this is what makes the guarantee real:
//  the address is derived from keccak256(orderId, buyer, seller). If the
//  backend tried to resolve the order towards any other party, it would have
//  to change those inputs, and CREATE2 would then deploy at a DIFFERENT
//  address — one holding no funds. The only freedom the backend keeps is the
//  `release` boolean: seller or buyer. Nothing else. Anyone can recompute the
//  address from public data and verify this.
// ═════════════════════════════════════════════════════════════════════════════

/// Single-use contract. It deploys, distributes inside the constructor, and
/// dies leaving no code. It takes no constructor arguments ON PURPOSE: that
/// keeps its initcode identical for every order, so the address depends only
/// on the salt (the Uniswap V3 pattern).
contract OrderPayout {
    constructor() {
        (address usdt, address to, address feeWallet, uint16 bps)
            = EscrowFactory(msg.sender).instructions();

        uint256 balance = ITRC20(usdt).balanceOf(address(this));
        if (balance == 0) return;   // diagnostics: no funds -> no revert, so it can be observed
        // Distribute what ACTUALLY arrived, not what was requested: the
        // buyer's exchange may have deducted its withdrawal fee (it happened
        // in production: 23 requested, 21.5 received). Whether that amount is
        // acceptable is the backend's decision, made BEFORE calling here.
        uint256 fee = (balance * bps) / 10000;
        if (fee > 0) SafeTransfer.send(usdt, feeWallet, fee);
        SafeTransfer.send(usdt, to, balance - fee);
    }
}

contract EscrowFactory {
    address public immutable USDT;
    address public immutable FEE_WALLET;    // immutable: cannot be redirected
    uint16  public immutable FEE_BPS;       // 1000 = 10%
    address public operator;                // the backend's key

    // Instructions the clone reads in its constructor. Written right before
    // the CREATE2 and cleared right after (the delete refunds part of the gas).
    struct Instruction { address usdt; address to; address feeWallet; uint16 bps; }
    Instruction private _instr;

    event OrderResolved(bytes32 indexed orderId, address indexed to, bool released, uint256 balance);
    /// DIAGNOSTICS: the real address CREATE2 deployed at, to compare against addressFor().
    event CloneDeployed(address clone, address computed);

    modifier onlyOperator() { require(msg.sender == operator, "not authorized"); _; }

    constructor(address usdt, address feeWallet, uint16 feeBps) {
        require(feeWallet != address(0) && feeBps <= 10000, "invalid parameters");
        USDT = usdt;
        FEE_WALLET = feeWallet;
        FEE_BPS = feeBps;
        operator = msg.sender;
    }

    function changeOperator(address next) external onlyOperator {
        require(next != address(0), "invalid operator");
        operator = next;   // rotate the backend key without touching where money can go
    }

    /// Read by the clone's constructor. Public because the clone calls it externally.
    function instructions() external view returns (address, address, address, uint16) {
        return (_instr.usdt, _instr.to, _instr.feeWallet, _instr.bps);
    }

    function _salt(bytes32 orderId, address buyer, address seller) internal pure returns (bytes32) {
        return keccak256(abi.encode(orderId, buyer, seller));
    }

    /// The address the buyer must pay to. Computable without deploying anything (cost 0).
    function addressFor(bytes32 orderId, address buyer, address seller)
        public view returns (address)
    {
        bytes32 h = keccak256(abi.encodePacked(
            bytes1(0x41),                       // Tron uses 0x41 where Ethereum uses 0xff
            address(this),
            _salt(orderId, buyer, seller),
            keccak256(type(OrderPayout).creationCode)
        ));
        return address(uint160(uint256(h)));
    }

    /// DIAGNOSTICS: Tron's TVM does not document CREATE2 address derivation
    /// well. This computes the candidate variants so they can be compared with
    /// the real address emitted by CloneDeployed. (Verified on-chain: the 0x41
    /// variant is the correct one.)
    function variants(bytes32 orderId, address buyer, address seller)
        external view returns (address v41, address vFF, address v4141, address vNoPrefix)
    {
        bytes32 salt = _salt(orderId, buyer, seller);
        bytes32 ic = keccak256(type(OrderPayout).creationCode);
        v41  = address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0x41), address(this), salt, ic)))));
        vFF  = address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, ic)))));
        v4141 = address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0x41), bytes1(0x41), address(this), salt, ic)))));
        vNoPrefix = address(uint160(uint256(keccak256(abi.encodePacked(address(this), salt, ic)))));
    }

    /// Deploys the ephemeral contract at the order's address and distributes the funds.
    /// `release = true`  → fee to the fixed wallet + remainder to the seller.
    /// `release = false` → 100% back to the buyer (no fee on refunds).
    function resolve(bytes32 orderId, address buyer, address seller, bool release)
        external onlyOperator
    {
        address to = release ? seller : buyer;
        _instr = Instruction({
            usdt: USDT,
            to: to,
            feeWallet: FEE_WALLET,
            bps: release ? FEE_BPS : 0
        });

        bytes32 salt = _salt(orderId, buyer, seller);
        address clone = address(new OrderPayout{salt: salt}());

        delete _instr;   // clear and refund part of the gas
        emit CloneDeployed(clone, addressFor(orderId, buyer, seller));
        emit OrderResolved(orderId, to, release, ITRC20(USDT).balanceOf(clone));
    }
}

// ═════════════════════════════════════════════════════════════════════════════
//  OPTION B — one contract shared by all orders
// ═════════════════════════════════════════════════════════════════════════════
//  Every buyer pays to THE SAME address, so the contract cannot know which
//  deposit belongs to whom (a contract cannot read chain logs). The backend —
//  which does see the chain from outside — has to tell it.
//
//  What the contract DOES guarantee: it cannot register more money than it
//  actually holds (the `totalCommitted <= balance` invariant), and the only
//  possible destinations remain seller, buyer, or the fixed fee wallet.
//  What it does NOT guarantee: that the split BETWEEN orders is correct.
//  That depends on the backend.
// ═════════════════════════════════════════════════════════════════════════════
contract SingleEscrow {
    address public immutable USDT;
    address public immutable FEE_WALLET;
    uint16  public immutable FEE_BPS;
    address public operator;

    struct Order { address buyer; address seller; uint256 amount; uint8 state; }  // 0=none,1=registered,2=released,3=refunded
    mapping(bytes32 => Order) public orders;
    uint256 public totalCommitted;

    modifier onlyOperator() { require(msg.sender == operator, "not authorized"); _; }

    constructor(address usdt, address feeWallet, uint16 feeBps) {
        require(feeWallet != address(0) && feeBps <= 10000, "invalid parameters");
        USDT = usdt; FEE_WALLET = feeWallet; FEE_BPS = feeBps;
        operator = msg.sender;
    }

    function registerDeposit(bytes32 orderId, address buyer, address seller, uint256 amount)
        public onlyOperator
    {
        require(orders[orderId].state == 0, "already registered");
        // PREVENTS invented deposits: money the contract does not hold cannot be committed.
        require(totalCommitted + amount <= ITRC20(USDT).balanceOf(address(this)), "insufficient balance");
        orders[orderId] = Order(buyer, seller, amount, 1);
        totalCommitted += amount;
    }

    function release(bytes32 orderId) public onlyOperator {
        Order storage o = orders[orderId];
        require(o.state == 1, "invalid state");
        o.state = 2;
        totalCommitted -= o.amount;
        uint256 fee = (o.amount * FEE_BPS) / 10000;
        if (fee > 0) SafeTransfer.send(USDT, FEE_WALLET, fee);
        SafeTransfer.send(USDT, o.seller, o.amount - fee);
    }

    function refund(bytes32 orderId) public onlyOperator {
        Order storage o = orders[orderId];
        require(o.state == 1, "invalid state");
        o.state = 3;
        totalCommitted -= o.amount;
        SafeTransfer.send(USDT, o.buyer, o.amount);
    }

    /// The real advantage of this option: settle N orders in ONE transaction.
    function releaseBatch(bytes32[] calldata ids) external onlyOperator {
        for (uint256 i = 0; i < ids.length; i++) release(ids[i]);
    }
}

// ═════════════════════════════════════════════════════════════════════════════
//  Test token (testnet ONLY). It imitates USDT, including its return-less
//  `transfer`.
// ═════════════════════════════════════════════════════════════════════════════
contract MockUSDT {
    string public name = "Mock USDT";
    uint8  public decimals = 18;          // like BSC's USDT (TRON/Ethereum use 6)
    mapping(address => uint256) public balanceOf;

    /// ESSENTIAL: without this event, on-chain verification (eth_getLogs) sees
    /// NOTHING. The first version of this mock did not emit it, and a live test
    /// reported 'no payment found' with the payment already on-chain — the
    /// classic mock trap: if the lab token does not behave like the real one,
    /// the test validates something that does not exist.
    event Transfer(address indexed from, address indexed to, uint256 value);

    constructor(uint256 supply) {
        balanceOf[msg.sender] = supply;
        emit Transfer(address(0), msg.sender, supply);
    }

    /// No return value, just like real USDT: this is what proves SafeTransfer
    /// works with the real token and not only with a well-behaved lab token.
    function transfer(address to, uint256 value) external {
        require(balanceOf[msg.sender] >= value, "insufficient balance");
        balanceOf[msg.sender] -= value;
        balanceOf[to] += value;
        emit Transfer(msg.sender, to, value);
    }
}
