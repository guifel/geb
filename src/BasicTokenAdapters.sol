/// BasicTokenAdapters.sol

// Copyright (C) 2018 Rain <rainbreak@riseup.net>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU Affero General Public License for more details.
//
// You should have received a copy of the GNU Affero General Public License
// along with this program.  If not, see <https://www.gnu.org/licenses/>.

pragma solidity ^0.6.7;

abstract contract CollateralLike {
    function decimals() virtual public view returns (uint);
    function transfer(address,uint) virtual public returns (bool);
    function transferFrom(address,address,uint) virtual public returns (bool);
}

abstract contract DSTokenLike {
    function mint(address,uint) virtual external;
    function burn(address,uint) virtual external;
}

abstract contract CDPEngineLike {
    function modifyCollateralBalance(bytes32,address,int) virtual external;
    function transferInternalCoins(address,address,uint) virtual external;
}

/*
    Here we provide *adapters* to connect the CDPEngine to arbitrary external
    token implementations, creating a bounded context for the CDPEngine. The
    adapters here are provided as working examples:
      - `BasicCollateralJoin`: For well behaved ERC20 tokens, with simple transfer semantics.
      - `ETHJoin`: For native Ether.
      - `CoinJoin`: For connecting internal coin balances to an external
                   `Coin` implementation.
    In practice, adapter implementations will be varied and specific to
    individual collateral types, accounting for different transfer
    semantics and token standards.
    Adapters need to implement two basic methods:
      - `join`: enter collateral into the system
      - `exit`: remove collateral from the system
*/

contract BasicCollateralJoin {
    // --- Auth ---
    mapping (address => uint) public authorizedAccounts;
    /**
     * @notice Add auth to an account
     * @param account Account to add auth to
     */
    function addAuthorization(address account) external isAuthorized {
        authorizedAccounts[account] = 1;
        emit AddAuthorization(account);
    }
    /**
     * @notice Remove auth from an account
     * @param account Account to remove auth from
     */
    function removeAuthorization(address account) external isAuthorized {
        authorizedAccounts[account] = 0;
        emit RemoveAuthorization(account);
    }
    /**
    * @notice Checks whether msg.sender can call an authed function
    **/
    modifier isAuthorized {
        require(authorizedAccounts[msg.sender] == 1, "BasicCollateralJoin/account-not-authorized");
        _;
    }

    // CDP database
    CDPEngineLike  public cdpEngine;
    // Collateral type name
    bytes32        public collateralType;
    // Actual collateral token contract
    CollateralLike public collateral;
    // How many decimals the collateral token has
    uint           public decimals;
    // Whether this adapter contract is enabled or not
    uint           public contractEnabled;

    // --- Events ---
    event AddAuthorization(address account);
    event RemoveAuthorization(address account);
    event DisableContract();
    event Join(address sender, address account, uint wad);
    event Exit(address sender, address account, uint wad);

    constructor(address cdpEngine_, bytes32 collateralType_, address collateral_) public {
        authorizedAccounts[msg.sender] = 1;
        contractEnabled = 1;
        cdpEngine       = CDPEngineLike(cdpEngine_);
        collateralType  = collateralType_;
        collateral      = CollateralLike(collateral_);
        decimals        = collateral.decimals();
        emit AddAuthorization(msg.sender);
    }
    /**
     * @notice Disable this contract
     */
    function disableContract() external isAuthorized {
        contractEnabled = 0;
        emit DisableContract();
    }
    /**
    * @notice Join collateral in the system
    * @dev This function locks collateral in the adapter and creates a 'representation' of
    *      the locked collateral inside the system. This adapter assumes that the collateral
    *      has 18 decimals
    * @param account Account from which we transferFrom collateral and add it in the system
    * @param wad Amount of collateral to transfer in the system (represented as a number with 18 decimals)
    **/
    function join(address account, uint wad) external {
        require(contractEnabled == 1, "BasicCollateralJoin/contract-not-enabled");
        require(int(wad) >= 0, "BasicCollateralJoin/overflow");
        cdpEngine.modifyCollateralBalance(collateralType, account, int(wad));
        require(collateral.transferFrom(msg.sender, address(this), wad), "BasicCollateralJoin/failed-transfer");
        emit Join(msg.sender, account, wad);
    }
    /**
    * @notice Exit collateral from the system
    * @dev This function destroys the collateral representation from inside the system
    *      and exits the collateral from this adapte. The adapter assumes that the collateral
    *      has 18 decimals
    * @param account Account to which we transfer the collateral
    * @param wad Amount of collateral to transfer to 'account' (represented as a number with 18 decimals)
    **/
    function exit(address account, uint wad) external {
        require(wad <= 2 ** 255, "BasicCollateralJoin/overflow");
        cdpEngine.modifyCollateralBalance(collateralType, msg.sender, -int(wad));
        require(collateral.transfer(account, wad), "BasicCollateralJoin/failed-transfer");
        emit Exit(msg.sender, account, wad);
    }
}

contract ETHJoin {
    // --- Auth ---
    mapping (address => uint) public authorizedAccounts;
    /**
     * @notice Add auth to an account
     * @param account Account to add auth to
     */
    function addAuthorization(address account) external isAuthorized {
        authorizedAccounts[account] = 1;
        emit AddAuthorization(account);
    }
    /**
     * @notice Remove auth from an account
     * @param account Account to remove auth from
     */
    function removeAuthorization(address account) external isAuthorized {
        authorizedAccounts[account] = 0;
        emit RemoveAuthorization(account);
    }
    /**
    * @notice Checks whether msg.sender can call an authed function
    **/
    modifier isAuthorized {
        require(authorizedAccounts[msg.sender] == 1, "ETHJoin/account-not-authorized");
        _;
    }

    // CDP database
    CDPEngineLike public cdpEngine;
    // Collateral type name
    bytes32       public collateralType;
    // Whether this contract is enabled or not
    uint          public contractEnabled;
    // Number of decimals ETH has
    uint          public decimals;

    // --- Events ---
    event AddAuthorization(address account);
    event RemoveAuthorization(address account);
    event DisableContract();
    event Join(address sender, address account, uint wad);
    event Exit(address sender, address account, uint wad);

    constructor(address cdpEngine_, bytes32 collateralType_) public {
        authorizedAccounts[msg.sender] = 1;
        contractEnabled                = 1;
        cdpEngine                      = CDPEngineLike(cdpEngine_);
        collateralType                 = collateralType_;
        decimals                       = 18;
        emit AddAuthorization(msg.sender);
    }
    /**
     * @notice Disable this contract
     */
    function disableContract() external isAuthorized {
        contractEnabled = 0;
        emit DisableContract();
    }
    /**
    * @notice Join ETH in the system
    * @param account Account that will receive the ETH representation inside the system
    **/
    function join(address account) external payable {
        require(contractEnabled == 1, "ETHJoin/contract-not-enabled");
        require(int(msg.value) >= 0, "ETHJoin/overflow");
        cdpEngine.modifyCollateralBalance(collateralType, account, int(msg.value));
        emit Join(msg.sender, account, msg.value);
    }
    /**
    * @notice Exit ETH from the system
    * @param account Account that will receive the ETH representation inside the system
    **/
    function exit(address payable account, uint wad) external {
        require(int(wad) >= 0, "ETHJoin/overflow");
        cdpEngine.modifyCollateralBalance(collateralType, msg.sender, -int(wad));
        emit Exit(msg.sender, account, wad);
        account.transfer(wad);
    }
}

contract CoinJoin {
    // --- Auth ---
    mapping (address => uint) public authorizedAccounts;
    /**
     * @notice Add auth to an account
     * @param account Account to add auth to
     */
    function addAuthorization(address account) external isAuthorized {
        authorizedAccounts[account] = 1;
        emit AddAuthorization(account);
    }
    /**
     * @notice Remove auth from an account
     * @param account Account to remove auth from
     */
    function removeAuthorization(address account) external isAuthorized {
        authorizedAccounts[account] = 0;
        emit RemoveAuthorization(account);
    }
    /**
    * @notice Checks whether msg.sender can call an authed function
    **/
    modifier isAuthorized {
        require(authorizedAccounts[msg.sender] == 1, "CoinJoin/account-not-authorized");
        _;
    }

    // CDP database
    CDPEngineLike public cdpEngine;
    // Coin created by the system; this is the external, ERC-20 representation, not the internal 'coinBalance'
    DSTokenLike   public systemCoin;
    // Whether this contract is enabled or not
    uint          public contractEnabled;
    // Number of decimals the system coin has
    uint          public decimals;

    // --- Events ---
    event AddAuthorization(address account);
    event RemoveAuthorization(address account);
    event DisableContract();
    event Join(address sender, address account, uint wad);
    event Exit(address sender, address account, uint wad);

    constructor(address cdpEngine_, address systemCoin_) public {
        authorizedAccounts[msg.sender] = 1;
        contractEnabled                = 1;
        cdpEngine                      = CDPEngineLike(cdpEngine_);
        systemCoin                     = DSTokenLike(systemCoin_);
        decimals                       = 18;
        emit AddAuthorization(msg.sender);
    }
    /**
     * @notice Disable this contract
     */
    function disableContract() external isAuthorized {
        contractEnabled = 0;
        emit DisableContract();
    }
    uint constant RAY = 10 ** 27;
    function multiply(uint x, uint y) internal pure returns (uint z) {
        require(y == 0 || (z = x * y) / y == x);
    }
    /**
    * @notice Join reflex-bonds/pegged-coins in the system
    * @dev Exited coins have 18 decimals but inside the system they have 45 (rad) decimals.
           When we join, the amount (wad) is multiplied by 10**27 (ray)
    * @param account Account that will receive the joined coins
    * @param wad Amount of external coins to join (18 decimal number)
    **/
    function join(address account, uint wad) external {
        cdpEngine.transferInternalCoins(address(this), account, multiply(RAY, wad));
        systemCoin.burn(msg.sender, wad);
        emit Join(msg.sender, account, wad);
    }
    /**
    * @notice Exit reflex-bonds/pegged-coins from the system and inside 'Coin.sol'
    * @dev Inside the system, coins have 45 (rad) decimals but outside they have 18 decimals (wad).
           When we exit, we specify a wad amount of coins and then the contract automatically multiplies
           wad by 10**27 to move the correct 45 decimal coin amount to this adapter
    * @param account Account that will receive the exited coins
    * @param wad Amount of internal coins to join (18 decimal number that will be multiplied by ray)
    **/
    function exit(address account, uint wad) external {
        require(contractEnabled == 1, "CoinJoin/contract-not-enabled");
        cdpEngine.transferInternalCoins(msg.sender, address(this), multiply(RAY, wad));
        systemCoin.mint(account, wad);
        emit Exit(msg.sender, account, wad);
    }
}
