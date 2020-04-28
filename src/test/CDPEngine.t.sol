pragma solidity ^0.5.15;
pragma experimental ABIEncoderV2;

import "ds-test/test.sol";
import "ds-token/token.sol";

import {CDPEngine} from '../CDPEngine.sol';
import {LiquidationEngine} from '../LiquidationEngine.sol';
import {AccountingEngine} from '../AccountingEngine.sol';
import {TaxCollector} from '../TaxCollector.sol';
import '../BasicTokenAdapters.sol';
import {OracleRelayer} from '../OracleRelayer.sol';

import {CollateralAuctionHouse} from './CollateralAuctionHouse.t.sol';
import {DebtAuctionHouse} from './DebtAuctionHouse.t.sol';
import {SurplusAuctionHouseTwo} from './SurplusAuctionHouse.t.sol';

contract Hevm {
    function warp(uint256) public;
}

contract Feed {
    bytes32 public price;
    bool public validPrice;
    uint public lastUpdateTime;
    constructor(uint256 price_, bool validPrice_) public {
        price = bytes32(price_);
        validPrice = validPrice_;
        lastUpdateTime = now;
    }
    function updateCollateralPrice(uint256 price_) external {
        price = bytes32(price_);
        lastUpdateTime = now;
    }
    function getPriceWithValidity() external view returns (bytes32, bool) {
        return (price, validPrice);
    }
}

contract TestCDPEngine is CDPEngine {
    uint256 constant RAY = 10 ** 27;

    constructor() public {}

    function mint(address usr, uint wad) public {
        coinBalance[usr] += wad * RAY;
        globalDebt += wad * RAY;
    }
    function balanceOf(address usr) public view returns (uint) {
        return uint(coinBalance[usr] / RAY);
    }
}

contract TestAccountingEngine is AccountingEngine {
    constructor(address cdpEngine, address surplusAuctionHouse, address debtAuctionHouse)
        public AccountingEngine(cdpEngine, surplusAuctionHouse, debtAuctionHouse) {}

    function totalDeficit() public view returns (uint) {
        return cdpEngine.debtBalance(address(this));
    }
    function totalSurplus() public view returns (uint) {
        return cdpEngine.coinBalance(address(this));
    }
    function preAuctionDebt() public view returns (uint) {
        return sub(sub(totalDeficit(), totalQueuedDebt), totalOnAuctionDebt);
    }
}

contract Usr {
    CDPEngine public cdpEngine;
    constructor(CDPEngine cdpEngine_) public {
        cdpEngine = cdpEngine_;
    }
    function try_call(address addr, bytes calldata data) external returns (bool) {
        bytes memory _data = data;
        assembly {
            let ok := call(gas, addr, 0, add(_data, 0x20), mload(_data), 0, 0)
            let free := mload(0x40)
            mstore(free, ok)
            mstore(0x40, add(free, 32))
            revert(free, 32)
        }
    }
    function can_modifyCDPCollateralization(
      bytes32 collateralType,
      address cdp,
      address collateralSource,
      address debtDestination,
      int deltaCollateral,
      int deltaDebt
    ) public returns (bool) {
        string memory sig = "modifyCDPCollateralization(bytes32,address,address,address,int256,int256)";
        bytes memory data = abi.encodeWithSignature(
          sig, collateralType, cdp, collateralSource, debtDestination, deltaCollateral, deltaDebt
        );

        bytes memory can_call = abi.encodeWithSignature("try_call(address,bytes)", cdpEngine, data);
        (bool ok, bytes memory success) = address(this).call(can_call);

        ok = abi.decode(success, (bool));
        if (ok) return true;
    }
    function can_transferCDPCollateralAndDebt(
      bytes32 collateralType, address src, address dst, int deltaCollateral, int deltaDebt
    ) public returns (bool) {
        string memory sig = "transferCDPCollateralAndDebt(bytes32,address,address,int256,int256)";
        bytes memory data = abi.encodeWithSignature(sig, collateralType, src, dst, deltaCollateral, deltaDebt);

        bytes memory can_call = abi.encodeWithSignature("try_call(address,bytes)", cdpEngine, data);
        (bool ok, bytes memory success) = address(this).call(can_call);

        ok = abi.decode(success, (bool));
        if (ok) return true;
    }
    function approve(address token, address target, uint wad) external {
        DSToken(token).approve(target, wad);
    }
    function join(address adapter, address cdp, uint wad) external {
        CollateralJoin(adapter).join(cdp, wad);
    }
    function exit(address adapter, address cdp, uint wad) external {
        CollateralJoin(adapter).exit(cdp, wad);
    }
    function modifyCDPCollateralization(
      bytes32 collateralType, address cdp, address collateralSrc, address debtDst, int deltaCollateral, int deltaDebt
    ) public {
        cdpEngine.modifyCDPCollateralization(collateralType, cdp, collateralSrc, debtDst, deltaCollateral, deltaDebt);
    }
    function transferCDPCollateralAndDebt(
      bytes32 collateralType, address src, address dst, int deltaCollateral, int deltaDebt
    ) public {
        cdpEngine.transferCDPCollateralAndDebt(collateralType, src, dst, deltaCollateral, deltaDebt);
    }
    function approveCDPModification(address usr) public {
        cdpEngine.approveCDPModification(usr);
    }
}

contract ModifyCDPCollateralizationTest is DSTest {
    TestCDPEngine cdpEngine;
    DSToken gold;
    DSToken stable;
    TaxCollector taxCollector;

    CollateralJoin collateralA;
    CollateralJoin collateralB;
    address me;

    Usr keeper;

    uint constant RAY = 10 ** 27;

    function try_modifyCDPCollateralization(bytes32 collateralType, int collateralToDeposit, int generatedDebt) public returns (bool ok) {
        string memory sig = "modifyCDPCollateralization(bytes32,address,address,address,int256,int256)";
        address self = address(this);
        (ok,) = address(cdpEngine).call(abi.encodeWithSignature(sig, collateralType, self, self, self, collateralToDeposit, generatedDebt));
    }

    function try_transferCDPCollateralAndDebt(bytes32 collateralType, address dst, int deltaCollateral, int deltaDebt) public returns (bool ok) {
        string memory sig = "transferCDPCollateralAndDebt(bytes32,address,address,int256,int256)";
        address self = address(this);
        (ok,) = address(cdpEngine).call(abi.encodeWithSignature(sig, collateralType, self, dst, deltaCollateral, deltaDebt));
    }

    function ray(uint wad) internal pure returns (uint) {
        return wad * 10 ** 9;
    }

    function setUp() public {
        cdpEngine = new TestCDPEngine();

        gold = new DSToken("GEM");
        gold.mint(1000 ether);

        stable = new DSToken("STA");
        stable.mint(1000 ether);

        cdpEngine.initializeCollateralType("gold");
        cdpEngine.initializeCollateralType("stable");

        collateralA = new CollateralJoin(address(cdpEngine), "gold", address(gold));
        collateralB = new CollateralJoin(address(cdpEngine), "stable", address(stable));

        cdpEngine.modifyParameters("gold", "safetyPrice",    ray(1 ether));
        cdpEngine.modifyParameters("gold", "debtCeiling", rad(1000 ether));
        cdpEngine.modifyParameters("stable", "safetyPrice",    ray(0.11 ether));
        cdpEngine.modifyParameters("stable", "debtCeiling", rad(1000 ether));
        cdpEngine.modifyParameters("globalDebtCeiling", rad(1000 ether));

        taxCollector = new TaxCollector(address(cdpEngine));
        taxCollector.initializeCollateralType("gold");
        taxCollector.initializeCollateralType("stable");
        cdpEngine.addAuthorization(address(taxCollector));

        gold.approve(address(collateralA));
        gold.approve(address(cdpEngine));

        stable.approve(address(collateralB));
        stable.approve(address(cdpEngine));

        cdpEngine.addAuthorization(address(cdpEngine));
        cdpEngine.addAuthorization(address(collateralA));
        cdpEngine.addAuthorization(address(collateralB));

        collateralA.join(address(this), 1000 ether);

        keeper = new Usr(cdpEngine);

        stable.transfer(address(keeper), 100 ether);

        keeper.approve(address(stable), address(collateralB), 2**255);
        keeper.join(address(collateralB), address(keeper), 100 ether);

        me = address(this);
    }

    function tokenCollateral(bytes32 collateralType, address cdp) internal view returns (uint) {
        return cdpEngine.tokenCollateral(collateralType, cdp);
    }
    function lockedCollateral(bytes32 collateralType, address cdp) internal view returns (uint) {
        (uint lockedCollateral_, uint generatedDebt_) =
          cdpEngine.cdps(collateralType, cdp); generatedDebt_;
        return lockedCollateral_;
    }
    function generatedDebt(bytes32 collateralType, address cdp) internal view returns (uint) {
        (uint lockedCollateral_, uint generatedDebt_) =
          cdpEngine.cdps(collateralType, cdp); lockedCollateral_;
        return generatedDebt_;
    }

    function test_setup() public {
        assertEq(gold.balanceOf(address(collateralA)), 1000 ether);
        assertEq(tokenCollateral("gold", address(this)), 1000 ether);
        assertEq(stable.balanceOf(address(keeper)), 0);
        assertEq(stable.balanceOf(address(collateralB)), 100 ether);
    }
    function test_join() public {
        address cdp = address(this);
        gold.mint(500 ether);
        assertEq(gold.balanceOf(address(this)),    500 ether);
        assertEq(gold.balanceOf(address(collateralA)),   1000 ether);
        collateralA.join(cdp,                             500 ether);
        assertEq(gold.balanceOf(address(this)),      0 ether);
        assertEq(gold.balanceOf(address(collateralA)),   1500 ether);
        collateralA.exit(cdp,                             250 ether);
        assertEq(gold.balanceOf(address(this)),    250 ether);
        assertEq(gold.balanceOf(address(collateralA)),   1250 ether);
    }
    function test_lock() public {
        assertEq(lockedCollateral("gold", address(this)), 0 ether);
        assertEq(tokenCollateral("gold", address(this)), 1000 ether);
        cdpEngine.modifyCDPCollateralization("gold", me, me, me, 6 ether, 0);
        assertEq(lockedCollateral("gold", address(this)),   6 ether);
        assertEq(tokenCollateral("gold", address(this)), 994 ether);
        cdpEngine.modifyCDPCollateralization("gold", me, me, me, -6 ether, 0);
        assertEq(lockedCollateral("gold", address(this)),    0 ether);
        assertEq(tokenCollateral("gold", address(this)), 1000 ether);
    }
    function test_calm() public {
        // calm means that the debt ceiling is not exceeded
        // it's ok to increase debt as long as you remain calm
        cdpEngine.modifyParameters("gold", 'debtCeiling', rad(10 ether));
        assertTrue( try_modifyCDPCollateralization("gold", 10 ether, 9 ether));
        // only if under debt ceiling
        assertTrue(!try_modifyCDPCollateralization("gold",  0 ether, 2 ether));
    }
    function test_cool() public {
        // cool means that the debt has decreased
        // it's ok to be over the debt ceiling as long as you're cool
        cdpEngine.modifyParameters("gold", 'debtCeiling', rad(10 ether));
        assertTrue(try_modifyCDPCollateralization("gold", 10 ether,  8 ether));
        cdpEngine.modifyParameters("gold", 'debtCeiling', rad(5 ether));
        // can decrease debt when over ceiling
        assertTrue(try_modifyCDPCollateralization("gold",  0 ether, -1 ether));
    }
    function test_safe() public {
        // safe means that the cdp is not risky
        // you can't frob a cdp into unsafe
        cdpEngine.modifyCDPCollateralization("gold", me, me, me, 10 ether, 5 ether); // safe draw
        assertTrue(!try_modifyCDPCollateralization("gold", 0 ether, 6 ether));  // unsafe draw
    }
    function test_nice() public {
        // nice means that the collateral has increased or the debt has
        // decreased. remaining unsafe is ok as long as you're nice

        cdpEngine.modifyCDPCollateralization("gold", me, me, me, 10 ether, 10 ether);
        cdpEngine.modifyParameters("gold", 'safetyPrice', ray(0.5 ether));  // now unsafe

        // debt can't increase if unsafe
        assertTrue(!try_modifyCDPCollateralization("gold",  0 ether,  1 ether));
        // debt can decrease
        assertTrue( try_modifyCDPCollateralization("gold",  0 ether, -1 ether));
        // lockedCollateral can't decrease
        assertTrue(!try_modifyCDPCollateralization("gold", -1 ether,  0 ether));
        // lockedCollateral can increase
        assertTrue( try_modifyCDPCollateralization("gold",  1 ether,  0 ether));

        // cdp is still unsafe
        // lockedCollateral can't decrease, even if debt decreases more
        assertTrue(!this.try_modifyCDPCollateralization("gold", -2 ether, -4 ether));
        // debt can't increase, even if lockedCollateral increases more
        assertTrue(!this.try_modifyCDPCollateralization("gold",  5 ether,  1 ether));

        // lockedCollateral can decrease if end state is safe
        assertTrue( this.try_modifyCDPCollateralization("gold", -1 ether, -4 ether));
        cdpEngine.modifyParameters("gold", 'safetyPrice', ray(0.4 ether));  // now unsafe
        // debt can increase if end state is safe
        assertTrue( this.try_modifyCDPCollateralization("gold",  5 ether, 1 ether));
    }

    function rad(uint wad) internal pure returns (uint) {
        return wad * 10 ** 27;
    }
    function test_alt_callers() public {
        Usr ali = new Usr(cdpEngine);
        Usr bob = new Usr(cdpEngine);
        Usr che = new Usr(cdpEngine);

        address a = address(ali);
        address b = address(bob);
        address c = address(che);

        cdpEngine.addAuthorization(a);
        cdpEngine.addAuthorization(b);
        cdpEngine.addAuthorization(c);

        cdpEngine.modifyCollateralBalance("gold", a, int(rad(20 ether)));
        cdpEngine.modifyCollateralBalance("gold", b, int(rad(20 ether)));
        cdpEngine.modifyCollateralBalance("gold", c, int(rad(20 ether)));

        ali.modifyCDPCollateralization("gold", a, a, a, 10 ether, 5 ether);

        // anyone can lock
        assertTrue( ali.can_modifyCDPCollateralization("gold", a, a, a,  1 ether,  0 ether));
        assertTrue( bob.can_modifyCDPCollateralization("gold", a, b, b,  1 ether,  0 ether));
        assertTrue( che.can_modifyCDPCollateralization("gold", a, c, c,  1 ether,  0 ether));
        // but only with their own tokenss
        assertTrue(!ali.can_modifyCDPCollateralization("gold", a, b, a,  1 ether,  0 ether));
        assertTrue(!bob.can_modifyCDPCollateralization("gold", a, c, b,  1 ether,  0 ether));
        assertTrue(!che.can_modifyCDPCollateralization("gold", a, a, c,  1 ether,  0 ether));

        // only the lad can frob
        assertTrue( ali.can_modifyCDPCollateralization("gold", a, a, a, -1 ether,  0 ether));
        assertTrue(!bob.can_modifyCDPCollateralization("gold", a, b, b, -1 ether,  0 ether));
        assertTrue(!che.can_modifyCDPCollateralization("gold", a, c, c, -1 ether,  0 ether));
        // the lad can frob to anywhere
        assertTrue( ali.can_modifyCDPCollateralization("gold", a, b, a, -1 ether,  0 ether));
        assertTrue( ali.can_modifyCDPCollateralization("gold", a, c, a, -1 ether,  0 ether));

        // only the lad can draw
        assertTrue( ali.can_modifyCDPCollateralization("gold", a, a, a,  0 ether,  1 ether));
        assertTrue(!bob.can_modifyCDPCollateralization("gold", a, b, b,  0 ether,  1 ether));
        assertTrue(!che.can_modifyCDPCollateralization("gold", a, c, c,  0 ether,  1 ether));
        // the lad can draw to anywhere
        assertTrue( ali.can_modifyCDPCollateralization("gold", a, a, b,  0 ether,  1 ether));
        assertTrue( ali.can_modifyCDPCollateralization("gold", a, a, c,  0 ether,  1 ether));

        cdpEngine.mint(address(bob), 1 ether);
        cdpEngine.mint(address(che), 1 ether);

        // anyone can wipe
        assertTrue( ali.can_modifyCDPCollateralization("gold", a, a, a,  0 ether, -1 ether));
        assertTrue( bob.can_modifyCDPCollateralization("gold", a, b, b,  0 ether, -1 ether));
        assertTrue( che.can_modifyCDPCollateralization("gold", a, c, c,  0 ether, -1 ether));
        // but only with their own coin
        assertTrue(!ali.can_modifyCDPCollateralization("gold", a, a, b,  0 ether, -1 ether));
        assertTrue(!bob.can_modifyCDPCollateralization("gold", a, b, c,  0 ether, -1 ether));
        assertTrue(!che.can_modifyCDPCollateralization("gold", a, c, a,  0 ether, -1 ether));
    }

    function test_approveCDPModification() public {
        Usr ali = new Usr(cdpEngine);
        Usr bob = new Usr(cdpEngine);
        Usr che = new Usr(cdpEngine);

        address a = address(ali);
        address b = address(bob);
        address c = address(che);

        cdpEngine.modifyCollateralBalance("gold", a, int(rad(20 ether)));
        cdpEngine.modifyCollateralBalance("gold", b, int(rad(20 ether)));
        cdpEngine.modifyCollateralBalance("gold", c, int(rad(20 ether)));

        cdpEngine.addAuthorization(a);
        cdpEngine.addAuthorization(b);
        cdpEngine.addAuthorization(c);

        ali.modifyCDPCollateralization("gold", a, a, a, 10 ether, 5 ether);

        // only owner can do risky actions
        assertTrue( ali.can_modifyCDPCollateralization("gold", a, a, a,  0 ether,  1 ether));
        assertTrue(!bob.can_modifyCDPCollateralization("gold", a, b, b,  0 ether,  1 ether));
        assertTrue(!che.can_modifyCDPCollateralization("gold", a, c, c,  0 ether,  1 ether));

        ali.approveCDPModification(address(bob));

        // unless they hope another user
        assertTrue( ali.can_modifyCDPCollateralization("gold", a, a, a,  0 ether,  1 ether));
        assertTrue( bob.can_modifyCDPCollateralization("gold", a, b, b,  0 ether,  1 ether));
        assertTrue(!che.can_modifyCDPCollateralization("gold", a, c, c,  0 ether,  1 ether));
    }

    function test_debtFloor() public {
        assertTrue( try_modifyCDPCollateralization("gold", 9 ether,  1 ether));
        cdpEngine.modifyParameters("gold", "debtFloor", rad(5 ether));
        assertTrue(!try_modifyCDPCollateralization("gold", 5 ether,  2 ether));
        assertTrue( try_modifyCDPCollateralization("gold", 0 ether,  5 ether));
        assertTrue(!try_modifyCDPCollateralization("gold", 0 ether, -5 ether));
        assertTrue( try_modifyCDPCollateralization("gold", 0 ether, -6 ether));
    }
}

// contract JoinTest is DSTest {
//     TestCDPEngine cdpEngine;
//     DSToken collateral;
//     CollateralJoin collateralA;
//     ETHJoin ethA;
//     CoinJoin coinA;
//     DSToken coin;
//     address me;
//
//     uint constant WAD = 10 ** 18;
//
//     function setUp() public {
//         cdpEngine = new TestCDPEngine();
//         cdpEngine.initializeCollateralType("ETH");
//
//         collateral  = new DSToken("Gem");
//         collateralA = new CollateralJoin(address(cdpEngine), "collateral", address(collateral));
//         cdpEngine.addAuthorization(address(collateralA));
//
//         ethA = new ETHJoin(address(cdpEngine), "ETH");
//         cdpEngine.addAuthorization(address(ethA));
//
//         coin  = new DSToken("Coin");
//         coinA = new CoinJoin(address(cdpEngine), address(coin));
//         cdpEngine.addAuthorization(address(coinA));
//         coin.setOwner(address(coinA));
//
//         me = address(this);
//     }
//     function draw(bytes32 collateralType, int wad, int coin_) internal {
//         address self = address(this);
//         cdpEngine.modifyCollateralBalance(collateralType, self, wad);
//         cdpEngine.modifyCDPCollateralization(collateralType, self, self, self, wad, coin_);
//     }
//     function try_cage(address a) public payable returns (bool ok) {
//         string memory sig = "cage()";
//         (ok,) = a.call(abi.encodeWithSignature(sig));
//     }
//     function try_join_tokenCollateral(address usr, uint wad) public returns (bool ok) {
//         string memory sig = "join(address,uint256)";
//         (ok,) = address(collateralA).call(abi.encodeWithSignature(sig, usr, wad));
//     }
//     function try_join_eth(address usr) public payable returns (bool ok) {
//         string memory sig = "join(address)";
//         (ok,) = address(ethA).call.value(msg.value)(abi.encodeWithSignature(sig, usr));
//     }
//     function try_exit_coin(address usr, uint wad) public returns (bool ok) {
//         string memory sig = "exit(address,uint256)";
//         (ok,) = address(coinA).call(abi.encodeWithSignature(sig, usr, wad));
//     }
//     function try_dres_tokenCollateral(int wad) public returns (bool ok) {
//         string memory sig = "dres(int256)";
//         (ok,) = address(collateralA).call(abi.encodeWithSignature(sig, wad));
//     }
//     function try_dres_eth(int wad) public payable returns (bool ok) {
//         string memory sig = "dres(int256)";
//         (ok,) = address(ethA).call.value(msg.value)(abi.encodeWithSignature(sig, wad));
//     }
//
//     function () external payable {}
//     function test_collateral_join() public {
//         collateral.mint(20 ether);
//         collateral.approve(address(collateralA), 20 ether);
//         assertTrue( try_join_tokenCollateral(address(this), 10 ether));
//         assertEq(cdpEngine.tokenCollateral("collateral", me), 10 ether);
//         assertTrue( try_cage(address(collateralA)));
//         assertTrue(!try_join_tokenCollateral(address(this), 10 ether));
//         assertEq(cdpEngine.tokenCollateral("collateral", me), 10 ether);
//     }
//     function test_eth_join() public {
//         assertTrue( this.try_join_eth.value(10 ether)(address(this)));
//         assertEq(cdpEngine.tokenCollateral("ETH", me), 10 ether);
//         assertTrue( try_cage(address(ethA)));
//         assertTrue(!this.try_join_eth.value(10 ether)(address(this)));
//         assertEq(cdpEngine.tokenCollateral("ETH", me), 10 ether);
//     }
//     function test_eth_exit() public {
//         address payable cdp = address(this);
//         ethA.join.value(50 ether)(cdp);
//         ethA.exit(cdp, 10 ether);
//         assertEq(cdpEngine.tokenCollateral("ETH", me), 40 ether);
//     }
//     function rad(uint wad) internal pure returns (uint) {
//         return wad * 10 ** 27;
//     }
//     function test_coin_exit() public {
//         address cdp = address(this);
//         cdpEngine.mint(address(this), 100 ether);
//         cdpEngine.approveCDPModification(address(coinA));
//         assertTrue( try_exit_coin(cdp, 40 ether));
//         assertEq(coin.balanceOf(address(this)), 40 ether);
//         assertEq(cdpEngine.coinBalance(me),              rad(60 ether));
//         assertTrue( try_cage(address(coinA)));
//         assertTrue(!try_exit_coin(cdp, 40 ether));
//         assertEq(coin.balanceOf(address(this)), 40 ether);
//         assertEq(cdpEngine.coinBalance(me),              rad(60 ether));
//     }
//     function test_coin_exit_join() public {
//         address cdp = address(this);
//         cdpEngine.mint(address(this), 100 ether);
//         cdpEngine.approveCDPModification(address(coinA));
//         coinA.exit(cdp, 60 ether);
//         coin.approve(address(coinA), uint(-1));
//         coinA.join(cdp, 30 ether);
//         assertEq(coin.balanceOf(address(this)),     30 ether);
//         assertEq(cdpEngine.coinBalance(me),                  rad(70 ether));
//     }
//     function test_fallback_reverts() public {
//         (bool ok,) = address(ethA).call("invalid calldata");
//         assertTrue(!ok);
//     }
//     function test_nonzero_fallback_reverts() public {
//         (bool ok,) = address(ethA).call.value(10)("invalid calldata");
//         assertTrue(!ok);
//     }
//     function test_cage_no_access() public {
//         collateralA.deny(address(this));
//         assertTrue(!try_cage(address(collateralA)));
//         ethA.deny(address(this));
//         assertTrue(!try_cage(address(ethA)));
//         coinA.deny(address(this));
//         assertTrue(!try_cage(address(coinA)));
//     }
// }
//
// contract FlipLike {
//     struct Bid {
//         uint256 bid;
//         uint256 lot;
//         address guy;  // high bidder
//         uint48  tic;  // expiry time
//         uint48  end;
//         address cdp;
//         address gal;
//         uint256 tab;
//     }
//     function bids(uint) public view returns (
//         uint256 bid,
//         uint256 lot,
//         address guy,
//         uint48  tic,
//         uint48  end,
//         address usr,
//         address gal,
//         uint256 tab
//     );
// }
//
// contract BiteTest is DSTest {
//     Hevm hevm;
//
//     TestCDPEngine cdpEngine;
//     TestAccountingEngine vow;
//     LiquidationEngine     cat;
//     DSToken gold;
//     TaxCollector     taxCollector;
//
//     CollateralJoin collateralA;
//
//     CollateralAuctionHouse flip;
//     DebtAuctionHouse flop;
//     SurplusAuctionHouseTwo flap;
//
//     DSToken gov;
//
//     address me;
//
//     function try_modifyCDPCollateralization(bytes32 collateralType, int lockedCollateral, int generatedDebt) public returns (bool ok) {
//         string memory sig = "modifyCDPCollateralization(bytes32,address,address,address,int256,int256)";
//         address self = address(this);
//         (ok,) = address(cdpEngine).call(abi.encodeWithSignature(sig, collateralType, self, self, self, lockedCollateral, generatedDebt));
//     }
//
//     function try_bite(bytes32 collateralType, address cdp) public returns (bool ok) {
//         string memory sig = "bite(bytes32,address)";
//         (ok,) = address(cat).call(abi.encodeWithSignature(sig, collateralType, cdp));
//     }
//
//     function ray(uint wad) internal pure returns (uint) {
//         return wad * 10 ** 9;
//     }
//     function rad(uint wad) internal pure returns (uint) {
//         return wad * 10 ** 27;
//     }
//
//     function tokenCollateral(bytes32 collateralType, address cdp) internal view returns (uint) {
//         return cdpEngine.tokenCollateral(collateralType, cdp);
//     }
//     function lockedCollateral(bytes32 collateralType, address cdp) internal view returns (uint) {
//         (uint lockedCollateral_, uint generatedDebt_) = cdpEngine.cdps(collateralType, cdp); generatedDebt_;
//         return lockedCollateral_;
//     }
//     function generatedDebt(bytes32 collateralType, address cdp) internal view returns (uint) {
//         (uint lockedCollateral_, uint generatedDebt_) = cdpEngine.cdps(collateralType, cdp); lockedCollateral_;
//         return generatedDebt_;
//     }
//
//     function setUp() public {
//         hevm = Hevm(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D);
//         hevm.warp(604411200);
//
//         gov = new DSToken('GOV');
//         gov.mint(100 ether);
//
//         cdpEngine = new TestCDPEngine();
//         cdpEngine = cdpEngine;
//
//         flap = new SurplusAuctionHouseTwo(address(cdpEngine));
//         //TODO: add gov and bond to surplusAuctionHouse
//         flop = new DebtAuctionHouse(address(cdpEngine), address(gov));
//
//         vow = new TestAccountingEngine(address(cdpEngine), address(flap), address(flop));
//         flap.addAuthorization(address(vow));
//         flop.addAuthorization(address(vow));
//         cdpEngine.addAuthorization(address(vow));
//
//         taxCollector = new TaxCollector(address(cdpEngine));
//         taxCollector.initializeCollateralType("gold");
//         taxCollector.modifyParameters("vow", address(vow));
//         cdpEngine.addAuthorization(address(taxCollector));
//
//         cat = new LiquidationEngine(address(cdpEngine));
//         cat.modifyParameters("vow", address(vow));
//         cdpEngine.addAuthorization(address(cat));
//         vow.addAuthorization(address(cat));
//
//         gold = new DSToken("GEM");
//         gold.mint(1000 ether);
//
//         cdpEngine.initializeCollateralType("gold");
//         collateralA = new CollateralJoin(address(cdpEngine), "gold", address(gold));
//         cdpEngine.addAuthorization(address(collateralA));
//         gold.approve(address(collateralA));
//         collateralA.join(address(this), 1000 ether);
//
//         cdpEngine.modifyParameters("gold", "safetyPrice", ray(1 ether));
//         cdpEngine.modifyParameters("gold", "debtCeiling", rad(1000 ether));
//         cdpEngine.modifyParameters("globalDebtCeiling",         rad(1000 ether));
//         flip = new CollateralAuctionHouse(address(cdpEngine), "gold");
//         flip.modifyParameters("oracleRelayer", address(new OracleRelayer(address(cdpEngine))));
//         flip.modifyParameters("orcl", address(new Feed(bytes32(uint256(1)), true)));
//         flip.addAuthorization(address(cat));
//         cat.modifyParameters("gold", "flip", address(flip));
//         cat.modifyParameters("gold", "chop", ray(1 ether));
//
//         cdpEngine.addAuthorization(address(flip));
//         cdpEngine.addAuthorization(address(flap));
//         cdpEngine.addAuthorization(address(flop));
//
//         cdpEngine.approveCDPModification(address(flip));
//         cdpEngine.approveCDPModification(address(flop));
//         gold.approve(address(cdpEngine));
//         gov.approve(address(flap));
//
//         me = address(this);
//     }
//
//     function test_bite_under_lump() public {
//         cdpEngine.modifyParameters("gold", 'safetyPrice', ray(5 ether));
//         cdpEngine.modifyParameters("gold", 'safetyPrice', ray(10 ether));
//         cdpEngine.modifyCDPCollateralization("gold", me, me, me, 40 ether, 100 ether);
//         // tag=4, mat=2
//         cdpEngine.modifyParameters("gold", 'safetyPrice', ray(1 ether));
//         cdpEngine.modifyParameters("gold", 'risk', ray(2 ether));  // now unsafe
//
//         cat.modifyParameters("gold", "lump", 50 ether);
//         cat.modifyParameters("gold", "chop", ray(1.1 ether));
//
//         uint auction = cat.bite("gold", address(this));
//         // the full CDP is liquidated
//         assertEq(lockedCollateral("gold", address(this)), 0);
//         assertEq(generatedDebt("gold", address(this)), 0);
//         // all debt goes to the vow
//         assertEq(vow.totalDeficit(), rad(100 ether));
//         // auction is for all collateral
//         (, uint lot,,,,,, uint tab) = FlipLike(address(flip)).bids(auction);
//         assertEq(lot,        40 ether);
//         assertEq(tab,   rad(110 ether));
//     }
//     function test_bite_over_lump() public {
//         cdpEngine.modifyParameters("gold", 'safetyPrice', ray(5 ether));
//         cdpEngine.modifyCDPCollateralization("gold", me, me, me, 40 ether, 100 ether);
//         // tag=4, mat=2
//         cdpEngine.modifyParameters("gold", 'safetyPrice', ray(1 ether));
//         cdpEngine.modifyParameters("gold", 'risk', ray(2 ether));  // now unsafe
//
//         cat.modifyParameters("gold", "chop", ray(1.1 ether));
//         cat.modifyParameters("gold", "lump", 30 ether);
//
//         uint auction = cat.bite("gold", address(this));
//         // the CDP is partially liquidated
//         assertEq(lockedCollateral("gold", address(this)), 10 ether);
//         assertEq(generatedDebt("gold", address(this)), 25 ether);
//         // a fraction of the debt goes to the vow
//         assertEq(vow.totalDeficit(), rad(75 ether));
//         // auction is for a fraction of the collateral
//         (, uint lot,,,,,, uint tab) = FlipLike(address(flip)).bids(auction);
//         assertEq(lot,       30 ether);
//         assertEq(tab,   rad(82.5 ether));
//     }
//
//     function test_bite_safetyPrice_when_risk() public {
//         cdpEngine.modifyParameters("gold", 'safetyPrice', ray(5 ether));
//         cdpEngine.modifyParameters("gold", 'risk', ray(10 ether));
//
//         cdpEngine.modifyCDPCollateralization("gold", me, me, me, 40 ether, 100 ether);
//
//         cdpEngine.modifyParameters("gold", 'safetyPrice', ray(2 ether));
//         cdpEngine.modifyParameters("gold", 'risk', ray(4 ether));
//
//         cat.modifyParameters("gold", "chop", ray(1.1 ether));
//         cat.modifyParameters("gold", "lump", 30 ether);
//
//         assertTrue(!try_bite("gold", address(this)));
//
//         cdpEngine.modifyParameters("gold", 'safetyPrice', ray(1 ether));
//         cdpEngine.modifyParameters("gold", 'risk', ray(2 ether));
//
//         assertTrue(try_bite("gold", address(this)));
//     }
//
//     function test_happy_bite() public {
//         // safetyPrice = tag / (par . mat)
//         // tag=5, mat=2
//         cdpEngine.modifyParameters("gold", 'safetyPrice', ray(5 ether));
//         cdpEngine.modifyCDPCollateralization("gold", me, me, me, 40 ether, 100 ether);
//
//         // tag=4, mat=2
//         cdpEngine.modifyParameters("gold", 'safetyPrice', ray(1 ether));
//         cdpEngine.modifyParameters("gold", 'risk', ray(2 ether));  // now unsafe
//
//         assertEq(lockedCollateral("gold", address(this)),  40 ether);
//         assertEq(generatedDebt("gold", address(this)), 100 ether);
//         assertEq(vow.preAuctionDebt(), 0 ether);
//         assertEq(tokenCollateral("gold", address(this)), 960 ether);
//
//         cat.modifyParameters("gold", "lump", 100 ether);  // => bite everything
//         uint auction = cat.bite("gold", address(this));
//         assertEq(lockedCollateral("gold", address(this)), 0);
//         assertEq(generatedDebt("gold", address(this)), 0);
//         assertEq(vow.debtBalance(now),   rad(100 ether));
//         assertEq(tokenCollateral("gold", address(this)), 960 ether);
//
//         assertEq(cdpEngine.balanceOf(address(vow)),    0 ether);
//         flip.tend(auction, 40 ether,   rad(1 ether));
//         flip.tend(auction, 40 ether, rad(100 ether));
//
//         assertEq(cdpEngine.balanceOf(address(this)),   0 ether);
//         assertEq(tokenCollateral("gold", address(this)),   960 ether);
//         cdpEngine.mint(address(this), 100 ether);  // magic up some dai for bidding
//         flip.dent(auction, 38 ether,  rad(100 ether));
//         assertEq(cdpEngine.balanceOf(address(this)), 100 ether);
//         assertEq(tokenCollateral("gold", address(this)),   962 ether);
//         assertEq(tokenCollateral("gold", address(this)),   962 ether);
//         assertEq(vow.debtBalance(now),     rad(100 ether));
//
//         hevm.warp(now + 4 hours);
//         flip.deal(auction);
//         assertEq(cdpEngine.balanceOf(address(vow)),  100 ether);
//     }
//
//     function test_floppy_bite() public {
//         cdpEngine.modifyParameters("gold", 'safetyPrice', ray(5 ether));
//         cdpEngine.modifyCDPCollateralization("gold", me, me, me, 40 ether, 100 ether);
//         cdpEngine.modifyParameters("gold", 'safetyPrice', ray(1 ether));
//         cdpEngine.modifyParameters("gold", 'risk', ray(2 ether));  // now unsafe
//
//         cat.modifyParameters("gold", "lump", 100 ether);  // => bite everything
//         assertEq(vow.debtBalance(now), rad(  0 ether));
//         cat.bite("gold", address(this));
//         assertEq(vow.debtBalance(now), rad(100 ether));
//
//         assertEq(vow.totalQueuedDebt(), rad(100 ether));
//         vow.popDebtFromQueue(now);
//         assertEq(vow.totalQueuedDebt(), rad(  0 ether));
//         assertEq(vow.preAuctionDebt(), rad(100 ether));
//         assertEq(vow.totalSurplus(), rad(  0 ether));
//         assertEq(vow.totalOnAuctionDebt(), rad(  0 ether));
//
//         vow.modifyParameters("sump", rad(10 ether));
//         vow.modifyParameters("dump", 2000 ether);
//         uint f1 = vow.flop();
//         assertEq(vow.preAuctionDebt(),  rad(90 ether));
//         assertEq(vow.totalSurplus(),  rad( 0 ether));
//         assertEq(vow.totalOnAuctionDebt(),  rad(10 ether));
//         flop.dent(f1, 1000 ether, rad(10 ether));
//         assertEq(vow.preAuctionDebt(),  rad(90 ether));
//         assertEq(vow.totalSurplus(),  rad( 0 ether));
//         assertEq(vow.totalOnAuctionDebt(),  rad( 0 ether));
//
//         assertEq(gov.balanceOf(address(this)),  100 ether);
//         hevm.warp(now + 4 hours);
//         gov.setOwner(address(flop));
//         flop.deal(f1);
//         assertEq(gov.balanceOf(address(this)), 1100 ether);
//     }
// }
//
// contract FoldTest is DSTest {
//     CDPEngine cdpEngine;
//
//     function ray(uint wad) internal pure returns (uint) {
//         return wad * 10 ** 9;
//     }
//     function rad(uint wad) internal pure returns (uint) {
//         return wad * 10 ** 27;
//     }
//     function tab(bytes32 collateralType, address cdp) internal view returns (uint) {
//         (uint lockedCollateral_, uint generatedDebt_) = cdpEngine.cdps(collateralType, cdp); lockedCollateral_;
//         (uint Art_, uint rate, uint safetyPrice, uint line, uint debtFloor, uint risk) = cdpEngine.collateralTypes(collateralType);
//         Art_; safetyPrice; line; debtFloor;
//         return generatedDebt_ * rate;
//     }
//     function jam(bytes32 collateralType, address cdp) internal view returns (uint) {
//         (uint lockedCollateral_, uint generatedDebt_) = cdpEngine.urns(collateralType, cdp); generatedDebt_;
//         return lockedCollateral_;
//     }
//
//     function setUp() public {
//         cdpEngine = new CDPEngine();
//         cdpEngine.initializeCollateralType("gold");
//         cdpEngine.modifyParameters("globalDebtCeiling", rad(100 ether));
//         cdpEngine.modifyParameters("gold", "debtCeiling", rad(100 ether));
//     }
//     function draw(bytes32 collateralType, uint coin) internal {
//         cdpEngine.modifyParameters("globalDebtCeiling", rad(coin));
//         cdpEngine.modifyParameters(collateralType, "debtCeiling", rad(coin));
//         cdpEngine.modifyParameters(collateralType, "safetyPrice", 10 ** 27 * 10000 ether);
//         address self = address(this);
//         cdpEngine.modifyCollateralBalance(collateralType, self,  10 ** 27 * 1 ether);
//         cdpEngine.modifyCDPCollateralization(collateralType, self, self, self, 1 ether, int(coin));
//     }
//     function test_fold() public {
//         address self = address(this);
//         address ali  = address(bytes20("ali"));
//         draw("gold", 1 ether);
//
//         assertEq(tab("gold", self), rad(1.00 ether));
//         cdpEngine.fold("gold", ali,   int(ray(0.05 ether)));
//         assertEq(tab("gold", self), rad(1.05 ether));
//         assertEq(cdpEngine.coinBalance(ali),      rad(0.05 ether));
//     }
// }