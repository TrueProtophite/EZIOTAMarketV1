// SPDX-License-Identifier: UNLICENSED

pragma solidity ^0.8.24;

import {ERC721Holder} from "@openzeppelin/contracts/token/ERC721/utils/ERC721Holder.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

contract EZIOTAMarketV1 is ERC721Holder, Ownable, ReentrancyGuard {
    using EnumerableSet for EnumerableSet.AddressSet;
    using EnumerableSet for EnumerableSet.UintSet;

    enum CollectionStatus {
        Pending,
        Open,
        Close
    }

    address public immutable FUEL;

    uint256 public constant TOTAL_MAX_FEE = 3000; 

    address public adminAddress;
    address public treasuryAddress;

    uint256 public minAskPrice; 
    uint256 public maxAskPrice; 

    uint256 public fuelRate; 

	uint256 public pendingRewardsTotal;

    mapping(address => uint256) public pendingRoyalties; 
    mapping(address => uint256) public pendingRewards;
    mapping(address => bool) public feesWithFuel;

    EnumerableSet.AddressSet private _collectionAddressSet;

    mapping(address => mapping(uint256 => Ask)) private _askDetails; 
    mapping(address => EnumerableSet.UintSet) private _askTokenIds; 
    mapping(address => Collection) private _collections; 
    mapping(address => mapping(address => EnumerableSet.UintSet)) private _tokenIdsOfSellerForCollection;

    struct Ask {
        address seller;
        uint256 price; 
    }

    struct Collection {
        CollectionStatus status; 
        address creatorAddress; 
        uint256 tradingFee;
        uint256 creatorFee; 
        uint256 tradeReward; 
    }

    event AskCancel(address indexed collection, address indexed seller, uint256 indexed tokenId);
    event AskNew(address indexed collection, address indexed seller, uint256 indexed tokenId, uint256 askPrice);
    event AskUpdate(address indexed collection, address indexed seller, uint256 indexed tokenId, uint256 askPrice);
    event CollectionClose(address indexed collection);
    event CollectionOpen(address indexed collection);
    event CollectionNew(address indexed collection, address indexed creator, uint256 tradingFee, uint256 creatorFee, uint256 tradeReward);
    event CollectionUpdate(address indexed collection, address indexed creator, uint256 tradingFee, uint256 creatorFee, uint256 tradeReward);
    event NewAdminAndTreasuryAddresses(address indexed admin, address indexed treasury);
    event NewMinAndMaxAskPrices(uint256 minAskPrice, uint256 maxAskPrice);
    event NewFUELRate(uint256 fuelRate);
    event RoyaltyClaim(address indexed claimer, uint256 amount);
    event RewardsClaim(address indexed claimer, uint256 amount);
    event Trade(address indexed collection, uint256 indexed tokenId, address indexed seller, address buyer, uint256 askPrice, uint256 netPrice);

    uint256 constant DECIMALS = 10;

    /**
     * @notice Constructor
     * @param _adminAddress: address of the admin
     * @param _treasuryAddress: address of the treasury
	 * @param _FUELAddress: FUEL Address
     * @param _fuelRate: FUEL /SMR Rate
     */
    constructor(address _adminAddress, address _treasuryAddress, address _FUELAddress, uint256 _fuelRate) Ownable(_adminAddress) {
        require(_adminAddress != address(0), "Operations: Admin address cannot be zero");
        require(_treasuryAddress != address(0), "Operations: Treasury address cannot be zero");
        require(_FUELAddress != address(0), "Operations: FUEL address cannot be zero");

        adminAddress = _adminAddress;
        treasuryAddress = _treasuryAddress;

        FUEL = _FUELAddress;

        fuelRate = _fuelRate;
    }

    function setTreasury(address newTreasury) external onlyOwner {
        require(newTreasury != address(0), "Address 0x00");
        treasuryAddress = newTreasury;
    }

	function withdrawFuel() external onlyOwner {
		IERC20(FUEL).transfer(adminAddress, IERC20(FUEL).balanceOf(address(this)) - pendingRewardsTotal);
	}	

	/**
	* @notice Toggle fee payable in fuel
	*/	
	function payFeesWithFuel() external {
		feesWithFuel[msg.sender] = !feesWithFuel[msg.sender];
	}

    /**
     * @notice Buy nft with SMR by matching the price of an existing ask order
     * @param _collection: contract address of the NFT
     * @param _tokenId: tokenId of the NFT purchased
     */
    function buyNFTIOTA(address _collection, uint256 _tokenId) external payable nonReentrant {
  		require(_collections[_collection].status == CollectionStatus.Open, "Collection: Not for trading");
        require(_askTokenIds[_collection].contains(_tokenId), "Buy: Not for sale");

        Ask memory askOrder = _askDetails[_collection][_tokenId];

        require(msg.value == askOrder.price, "Buy: Incorrect price");
        require(msg.sender != askOrder.seller, "Buy: Buyer cannot be seller");

        (uint256 netPrice, uint256 tradingFee, uint256 creatorFee, uint256 tradeReward) = _calculateNFTDistribution(_collection, msg.value);

		uint256 treasuryShare = 0;
        if(feesWithFuel[askOrder.seller]){
			uint256 fuelAmount = tradingFee - (tradingFee * (20 * (10 ** 2))) / (100 * (10 ** 2));
			netPrice += tradingFee;
			IERC20(FUEL).transferFrom(askOrder.seller, treasuryAddress, fuelAmount / fuelRate * DECIMALS ** 6);
 		}
		
		if (tradeReward > 0){
			uint256 fuelAmount = tradeReward / fuelRate * DECIMALS ** 6;
			pendingRewards[msg.sender] += fuelAmount;
			pendingRewardsTotal += fuelAmount;
			treasuryShare += tradeReward;
		}

		pendingRoyalties[_collections[_collection].creatorAddress] += creatorFee;
        pendingRoyalties[treasuryAddress] += treasuryShare;

        _tokenIdsOfSellerForCollection[askOrder.seller][_collection].remove(_tokenId);
        delete _askDetails[_collection][_tokenId];
        _askTokenIds[_collection].remove(_tokenId);

		payable(askOrder.seller).transfer(netPrice);
        IERC721(_collection).safeTransferFrom(address(this), msg.sender, _tokenId);

        emit Trade(_collection, _tokenId, askOrder.seller, msg.sender, msg.value, netPrice);
    }

    /**
     * @notice Cancel existing ask order
     * @param _collection: contract address of the NFT
     * @param _tokenId: tokenId of the NFT
     */
    function cancelAskOrder(address _collection, uint256 _tokenId) external nonReentrant {
        require(_tokenIdsOfSellerForCollection[msg.sender][_collection].contains(_tokenId), "Order: Token not listed");

        _tokenIdsOfSellerForCollection[msg.sender][_collection].remove(_tokenId);
        delete _askDetails[_collection][_tokenId];
        _askTokenIds[_collection].remove(_tokenId);

        IERC721(_collection).transferFrom(address(this), address(msg.sender), _tokenId);

        emit AskCancel(_collection, msg.sender, _tokenId);
    }

    /**
     * @notice Claim pending revenue (treasury or creators)
     */
    function claimRoyalties() external nonReentrant {
	    payable(msg.sender).transfer(pendingRoyalties[msg.sender]);	
        emit RoyaltyClaim(msg.sender, pendingRoyalties[msg.sender]);
        pendingRoyalties[msg.sender] = 0;
    }

    /**
     * @notice Claim pending revenue (treasury or creators)
     */
    function claimRewards() external nonReentrant {
        IERC20(FUEL).transfer(msg.sender, pendingRewards[msg.sender]);
        emit RewardsClaim(msg.sender, pendingRewards[msg.sender]);
		pendingRewardsTotal -= pendingRewards[msg.sender];
        pendingRewards[msg.sender] = 0;
    }

    /**
     * @notice Create ask order
     * @param _collection: contract address of the NFT
     * @param _tokenId: tokenId of the NFT
     * @param _askPrice: price for listing (in wei)
     */
    function createAskOrder(address _collection, uint256 _tokenId, uint256 _askPrice) external nonReentrant {
        require(_askPrice >= minAskPrice && _askPrice <= maxAskPrice, "Order: Price not within range");
        require(_collections[_collection].status == CollectionStatus.Open, "Collection: Not for listing");

        IERC721(_collection).safeTransferFrom(msg.sender, address(this), _tokenId);

        _tokenIdsOfSellerForCollection[msg.sender][_collection].add(_tokenId);
        _askDetails[_collection][_tokenId] = Ask({seller: msg.sender, price: _askPrice});
        _askTokenIds[_collection].add(_tokenId);

        emit AskNew(_collection, msg.sender, _tokenId, _askPrice);
    }

    /**
     * @notice Modify existing ask order
     * @param _collection: contract address of the NFT
     * @param _tokenId: tokenId of the NFT
     * @param _newPrice: new price for listing (in wei)
     */
    function modifyAskOrder(address _collection, uint256 _tokenId, uint256 _newPrice) external nonReentrant {
        require(_newPrice >= minAskPrice && _newPrice <= maxAskPrice, "Order: Price not within range");
        require(_collections[_collection].status == CollectionStatus.Open, "Collection: Not for listing");
        require(_tokenIdsOfSellerForCollection[msg.sender][_collection].contains(_tokenId), "Order: Token not listed");

        _askDetails[_collection][_tokenId].price = _newPrice;

        emit AskUpdate(_collection, msg.sender, _tokenId, _newPrice);
    }

    /**
     * @notice Add a new collection
     * @param _collection: collection address
     * @param _creator: creator address (must be 0x00 if none)
     * @param _tradingFee: trading fee (100 = 1%, 500 = 5%, 5 = 0.05%)
     * @param _creatorFee: creator fee (100 = 1%, 500 = 5%, 5 = 0.05%, 0 if creator is 0x00)
     * @param _tradeReward: trade reward (taken from the creatorFee, 0 if reward is 0x00)
     * @dev Callable by admin
     */
    function addCollection(address _collection, address _creator, uint256 _tradingFee, uint256 _creatorFee, uint256 _tradeReward) external onlyOwner {
        require(!_collectionAddressSet.contains(_collection), "Operations: Collection already listed");

		require(_tradeReward <= _creatorFee, "Trade reward exceeds creator fee");
		require(_creator != address(0), "Address 0x00");

        require(_tradingFee + _creatorFee <= TOTAL_MAX_FEE, "Operations: Sum of fee must inferior to TOTAL_MAX_FEE");

        _collectionAddressSet.add(_collection);

        _collections[_collection] = Collection({
            status: CollectionStatus.Open,
            creatorAddress: _creator,
            tradingFee: _tradingFee,
            creatorFee: _creatorFee,
            tradeReward: _tradeReward
        });

        emit CollectionNew(_collection, _creator, _tradingFee, _creatorFee, _tradeReward);
    }

    /**
     * @notice Allows the admin to pause a collection for trading and new listing
     * @param _collection: collection address
     * @dev Callable by admin
     */
    function pauseCollection(address _collection) external onlyOwner {
        require(_collectionAddressSet.contains(_collection), "Operations: Collection not listed");
        _collections[_collection].status = CollectionStatus.Close;
        emit CollectionClose(_collection);
    }

    function openCollection(address _collection) external onlyOwner {
        require(_collectionAddressSet.contains(_collection), "Operations: Collection not listed");
        _collections[_collection].status = CollectionStatus.Open;
        emit CollectionOpen(_collection);
    }

    /**
     * @notice Modify collection characteristics
     * @param _collection: collection address
     * @param _creator: creator address (must be 0x00 if none)
     * @param _tradingFee: trading fee (100 = 1%, 500 = 5%, 5 = 0.05%)
     * @param _creatorFee: creator fee (100 = 1%, 500 = 5%, 5 = 0.05%, 0 if creator is 0x00)
     * @param _tradeReward: trade reward (taken from creatorFee, 0 if creator is 0x00)
     * @dev Callable by admin
     */
    function modifyCollection(address _collection, address _creator, uint256 _tradingFee, uint256 _creatorFee, uint256 _tradeReward) external onlyOwner {
        require(_collectionAddressSet.contains(_collection), "Operations: Collection not listed");
		require(_tradeReward <= _creatorFee, "Trade reward exceeds creator fee");
		require(_creator != address(0), "Creator null address");
        require(_tradingFee + _creatorFee <= TOTAL_MAX_FEE, "Operations: Sum of fee must inferior to TOTAL_MAX_FEE");

        _collections[_collection] = Collection({
            status: CollectionStatus.Open,
            creatorAddress: _creator,
            tradingFee: _tradingFee,
            creatorFee: _creatorFee,
            tradeReward: _tradeReward
        });

        emit CollectionUpdate(_collection, _creator, _tradingFee, _creatorFee, _tradeReward);
    }

    /**
     * @notice Allows the admin to update minimum and maximum prices for a token (in wei)
     * @param _minAskPrice: minimum ask price
     * @param _maxAskPrice: maximum ask price
     * @dev Callable by admin
     */
    function updateMinMax(uint256 _minAskPrice, uint256 _maxAskPrice) external onlyOwner {
        require(_minAskPrice < _maxAskPrice, "Operations: _minAskPrice < _maxAskPrice");
        minAskPrice = _minAskPrice;
        maxAskPrice = _maxAskPrice;
        emit NewMinAndMaxAskPrices(_minAskPrice, _maxAskPrice);
    }

    /**
     * @notice Allows the admin to update the FUEL Rate
     * @param _fuelRate: FUEL / SMR Rate
     * @dev Callable by admin
     */
    function updateFuelRate(uint256 _fuelRate) external onlyOwner {
        fuelRate = _fuelRate;
        emit NewFUELRate(_fuelRate);
    }

    /**
     * @notice Check asks for an array of tokenIds in a collection
     * @param collection: address of the collection
     * @param tokenIds: array of tokenId
     */
    function viewAsksByTokenIds(address collection, uint256[] calldata tokenIds) external view returns (bool[] memory statuses, Ask[] memory askInfo){
        uint256 length = tokenIds.length;

        statuses = new bool[](length);
        askInfo = new Ask[](length);

        for (uint256 i = 0; i < length; i++) {
            if (_askTokenIds[collection].contains(tokenIds[i])) {
                statuses[i] = true;
            } else {
                statuses[i] = false;
            }

            askInfo[i] = _askDetails[collection][tokenIds[i]];
        }

        return (statuses, askInfo);
    }

    /**
     * @notice View ask orders for a given collection across all sellers
     * @param collection: address of the collection
     * @param cursor: cursor
     * @param size: size of the response
     */
    function viewAsksByCollection( address collection, uint256 cursor,  uint256 size)  external view returns (uint256[] memory tokenIds, Ask[] memory askInfo, uint256) {
        uint256 length = size;

        if (length > _askTokenIds[collection].length() - cursor) {
            length = _askTokenIds[collection].length() - cursor;
        }

        tokenIds = new uint256[](length);
        askInfo = new Ask[](length);

        for (uint256 i = 0; i < length; i++) {
            tokenIds[i] = _askTokenIds[collection].at(cursor + i);
            askInfo[i] = _askDetails[collection][tokenIds[i]];
        }

        return (tokenIds, askInfo, cursor + length);
    }

    /**
     * @notice View ask orders for a given collection and a seller
     * @param collection: address of the collection
     * @param seller: address of the seller
     * @param cursor: cursor
     * @param size: size of the response
     */
    function viewAsksByCollectionSeller(address collection, address seller, uint256 cursor, uint256 size) external view returns (uint256[] memory tokenIds, Ask[] memory askInfo, uint256){
        uint256 length = size;

        if (length > _tokenIdsOfSellerForCollection[seller][collection].length() - cursor) {
            length = _tokenIdsOfSellerForCollection[seller][collection].length() - cursor;
        }

        tokenIds = new uint256[](length);
        askInfo = new Ask[](length);

        for (uint256 i = 0; i < length; i++) {
            tokenIds[i] = _tokenIdsOfSellerForCollection[seller][collection].at(cursor + i);
            askInfo[i] = _askDetails[collection][tokenIds[i]];
        }

        return (tokenIds, askInfo, cursor + length);
    }

    /*
     * @notice View addresses and details for all the collections available for trading
     * @param cursor: cursor
     * @param size: size of the response
     */
    function viewCollections(uint256 cursor, uint256 size) external view returns (address[] memory collectionAddresses, Collection[] memory collectionDetails, uint256){
        uint256 length = size;

        if (length > _collectionAddressSet.length() - cursor) {
            length = _collectionAddressSet.length() - cursor;
        }

        collectionAddresses = new address[](length);
        collectionDetails = new Collection[](length);

        for (uint256 i = 0; i < length; i++) {
            collectionAddresses[i] = _collectionAddressSet.at(cursor + i);
            collectionDetails[i] = _collections[collectionAddresses[i]];
        }

        return (collectionAddresses, collectionDetails, cursor + length);
    }

    /**
     * @notice Calculate price and associated fees for a collection
     * @param collection: address of the collection
     * @param price: listed price
     */
    function calculateNFTDistribution(address collection, uint256 price) external view returns (uint256 netPrice, uint256 tradingFee, uint256 creatorFee, uint256 tradeReward) {
        return (_calculateNFTDistribution(collection, price));
    }

    /**
     * @notice Calculate price and associated fees for a collection
     * @param _collection: address of the collection
     * @param _askPrice: listed price
     */
    function _calculateNFTDistribution(address _collection, uint256 _askPrice) internal view returns (uint256 netPrice, uint256 tradingFee, uint256 creatorFee, uint256 tradeReward){
        tradingFee = (_askPrice * _collections[_collection].tradingFee) / 10000;
        creatorFee = (_askPrice * (_collections[_collection].creatorFee - _collections[_collection].tradeReward)) / 10000;
        tradeReward = (_askPrice * _collections[_collection].tradeReward) / 10000;
        netPrice = _askPrice - tradingFee - creatorFee - tradeReward;
        return (netPrice, tradingFee, creatorFee, tradeReward);
    }
}
