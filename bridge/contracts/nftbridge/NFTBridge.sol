// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;
pragma abicoder v2;


// Import base Initializable contract
import "../zeppelin/upgradable/Initializable.sol";
// Import interface and library from OpenZeppelin contracts
import "../zeppelin/upgradable/utils/ReentrancyGuard.sol";
import "../zeppelin/upgradable/lifecycle/UpgradablePausable.sol";
import "../zeppelin/upgradable/ownership/UpgradableOwnable.sol";

import "../zeppelin/introspection/IERC1820Registry.sol";
import "../zeppelin/token/ERC20/IERC20.sol";
import "../zeppelin/token/ERC20/SafeERC20.sol";
import "../zeppelin/token/ERC721/IERC721.sol";
import "../zeppelin/token/ERC721/IERC721Metadata.sol";
import "../zeppelin/token/ERC721/IERC721Enumerable.sol";
import "../zeppelin/token/ERC721/IERC721Receiver.sol";
import "../zeppelin/token/ERC721/ERC721Burnable.sol";
import "../zeppelin/utils/Address.sol";
import "../zeppelin/math/SafeMath.sol";

import "../lib/LibEIP712.sol";
import "../lib/LibUtils.sol";

import "./INFTBridge.sol";
import "./ISideNFTToken.sol";
import "./ISideNFTTokenFactory.sol";
import "../interface/IAllowTokens.sol";
import "../interface/IWrapped.sol";

// solhint-disable-next-line max-states-count
contract NFTBridge is
  Initializable,
  INFTBridge,
  UpgradablePausable,
  UpgradableOwnable,
  ReentrancyGuard,
  IERC721Receiver {
  using SafeMath for uint256;
  using SafeERC20 for IERC20;
  using Address for address;

  address internal constant NULL_ADDRESS = address(0);
  bytes32 internal constant NULL_HASH = bytes32(0);
  IERC1820Registry internal constant ERC1820 =
      IERC1820Registry(0x1820a4B7618BdE71Dce8cdc73aAB6C95905faD24);

  address payable internal federation;
  uint256 internal fixedFee;

  mapping(uint256 => mapping(address => address)) public sideTokenByOriginalTokenByChain;
  mapping(address => OriginalNft) public originalTokenBySideToken;
  mapping(uint256 => mapping(address => bool)) public isAddressFromCrossedOriginalTokenByChain; // uint256 => address => returns true if it's an original token address crossed previously (whether it comes from main or side chain)
  mapping(bytes32 => bool) public claimed; // transactionDataHash => true // previously named processed

  IAllowTokens public allowTokens;
  ISideNFTTokenFactory public sideTokenFactory;
  bool public isUpgrading;
  mapping(bytes32 => bytes32) public transactionDataHashes; // transactionHash => transactionDataHash

  event AllowTokensChanged(address _newAllowTokens);
  event FederationChanged(address _newFederation);
  event SideTokenFactoryChanged(address _newSideNFTTokenFactory);
  event Upgrading(bool _isUpgrading);

  function initialize(
    address _manager,
    address payable _federation,
    address _allowTokens,
    address _sideTokenFactory
  ) public initializer {
    UpgradableOwnable.initialize(_manager);
    UpgradablePausable.__Pausable_init(_manager);
    allowTokens = IAllowTokens(_allowTokens);
    sideTokenFactory = ISideNFTTokenFactory(_sideTokenFactory);
    federation = _federation;
    ERC1820.setInterfaceImplementer(
      address(this),
      0xb281fc8c12954d22544db45de3159a39272895b169a852b314f9cc762e44c53b,
      address(this)
    );
  }

  function version() external pure override returns (string memory) {
    return "v1";
  }

  modifier whenNotUpgrading() {
    require(!isUpgrading, "Bridge: Upgrading");
    _;
  }

  function acceptTransfer(
    address _tokenAddress,
    address payable _from,
    address payable _to,
    uint256 _tokenId,
    bytes32 _blockHash,
    bytes32 _transactionHash,
    uint32 _logIndex,
    uint256 _originChainId,
  uint256	_destinationChainId
  ) external whenNotPaused nonReentrant override {
    require(_msgSender() == federation, "NFTBridge: Not Federation");
    checkChainId(_originChainId);
    shouldBeCurrentChainId(_destinationChainId);
    require(
      isAddressFromCrossedOriginalToken(_originChainId, _tokenAddress) ||
      getSideTokenByOriginalToken(_originChainId, _tokenAddress) != NULL_ADDRESS,
      "NFTBridge: Unknown token"
    );
    require(_to != NULL_ADDRESS, "NFTBridge: Null To");
    require(_from != NULL_ADDRESS, "NFTBridge: Null From");
    require(_blockHash != NULL_HASH, "NFTBridge: Null BlockHash");
    require(_transactionHash != NULL_HASH, "NFTBridge: Null TxHash");
    require(
      transactionDataHashes[_transactionHash] == bytes32(0),
      "NFTBridge: Already accepted"
    );

    bytes32 _transactionDataHash = getTransactionDataHash(
      _to,
      _from,
      _tokenId,
      _tokenAddress,
      _blockHash,
      _transactionHash,
      _logIndex,
      _originChainId,
	    _destinationChainId
    );

    // Do not remove, claimed will also have transactions previously processed using older bridge versions
    require(!claimed[_transactionDataHash], "NFTBridge: Already claimed");
    transactionDataHashes[_transactionHash] = _transactionDataHash;
//    tokenAddressByTransactionHash[_transactionHash] = _tokenAddress;
//    senderAddresses[_transactionHash] = _from;

    emit AcceptedNFTCrossTransfer(
      _transactionHash,
      _tokenAddress,
      _to,
      _from,
      _tokenId,
      _blockHash,
      _logIndex,
      _originChainId,
	    _destinationChainId
    );
  }

  function shouldBeCurrentChainId(uint256 chainId) internal view {
    require(chainId == block.chainid, "NFTBridge: Not block.chainid");
  }

  function getSideTokenByOriginalToken(uint256 chainId, address originalToken) public view returns(address) {
    return sideTokenByOriginalTokenByChain[chainId][originalToken];
  }

  function _setSideTokenByOriginalToken(uint256 chainId, address originalToken, address sideToken) internal {
    sideTokenByOriginalTokenByChain[chainId][originalToken] = sideToken;
  }

  function getOriginalTokenBySideToken(address sideToken) public view returns(OriginalNft memory) {
    return originalTokenBySideToken[sideToken];
  }

  function _setOriginalTokenBySideToken(address sideToken, OriginalNft memory originalToken) internal {
    originalTokenBySideToken[sideToken] = originalToken;
  }

  function isAddressFromCrossedOriginalToken(uint256 chainId, address originalToken) public view returns(bool addressHasCrossed) {
    return isAddressFromCrossedOriginalTokenByChain[chainId][originalToken];
  }

  function _setAddressFromCrossedOriginalToken(uint256 chainId, address originalToken, bool addressHasCrossed) internal {
    isAddressFromCrossedOriginalTokenByChain[chainId][originalToken] = addressHasCrossed;
  }

  function createSideNFTToken(
    address _originalTokenAddress,
    string calldata _tokenSymbol,
    string calldata _tokenName,
    string calldata _baseURI,
    string calldata _contractURI,
    uint256 originChainId
  ) external onlyOwner {
    require(_originalTokenAddress != NULL_ADDRESS, "NFTBridge: Null original token address");

    require(getSideTokenByOriginalToken(originChainId, _originalTokenAddress) == NULL_ADDRESS, "NFTBridge: Side token already exists");

    // Create side token
    address sideTokenAddress = sideTokenFactory.createSideNFTToken(_tokenName, _tokenSymbol, _baseURI, _contractURI);

    _setSideTokenByOriginalToken(originChainId, _originalTokenAddress, sideTokenAddress);

    OriginalNft memory originalNft;
    originalNft.originChainId = originChainId;
    originalNft.nftAddress = _originalTokenAddress;
    _setOriginalTokenBySideToken(sideTokenAddress, originalNft);

    emit NewSideNFTToken(sideTokenAddress, _originalTokenAddress, _tokenSymbol, originChainId);
  }

  function checkChainId(uint256 chainId) internal pure {
    require(chainId > 0, "NFTBridge: ChainId is 0");
  }

  function claim(NFTClaimData calldata _claimData) external override {
    _claim(_claimData, _claimData.to);
  }

  function claimFallback(NFTClaimData calldata _claimData) external override {
    require(_msgSender() == _claimData.from, "NFTBridge: invalid sender");
    _claim(_claimData, _msgSender());
  }

  function _claim(
    NFTClaimData calldata _claimData,
    address payable _receiver
  ) internal {
    address tokenAddress = _claimData.tokenAddress;
    uint256 tokenId = _claimData.tokenId;

    bytes32 transactionDataHash = getTransactionDataHash(
      _claimData.to,
      _claimData.from,
      tokenId,
      tokenAddress,
      _claimData.blockHash,
      _claimData.transactionHash,
      _claimData.logIndex,
      _claimData.originChainId,
      block.chainid
    );


    require(
      transactionDataHashes[_claimData.transactionHash] == transactionDataHash,
      "NFTBridge: Wrong txDataHash"
    );
    require(!claimed[transactionDataHash], "NFTBridge: Already claimed");

    claimed[transactionDataHash] = true;
    if (isAddressFromCrossedOriginalToken(_claimData.originChainId, tokenAddress)) {
      IERC721(tokenAddress).safeTransferFrom(address(this), _receiver, tokenId);
    } else {
      address sideTokenAddress = getSideTokenByOriginalToken(_claimData.originChainId, tokenAddress);
      ISideNFTToken(sideTokenAddress).mint(_receiver, tokenId);
    }

    emit ClaimedNFTToken(
      _claimData.transactionHash,
      tokenAddress,
      _claimData.to,
      _claimData.from,
      _claimData.tokenId,
      _claimData.blockHash,
      _claimData.logIndex,
      _receiver,
      _claimData.originChainId,
      block.chainid
    );
  }

  function getTokenCreator(address tokenAddress, uint256 tokenId) public view returns (address) {
    (bool success, bytes memory data) = tokenAddress.staticcall(abi.encodeWithSignature("creator()"));
    if (success) {
      return abi.decode(data, (address));
    }

    return IERC721(tokenAddress).ownerOf(tokenId);
  }

  /**
    * ERC-20 tokens approve and transferFrom pattern
    * See https://eips.ethereum.org/EIPS/eip-20#transferfrom
    */
  function receiveTokensTo(
    address tokenAddress,
    address to,
    uint256 tokenId,
    uint256 destinationChainId
  ) public payable override {
    address tokenCreator = getTokenCreator(tokenAddress, tokenId);
    address payable sender = _msgSender();
    // Transfer the tokens on IERC721, they should be already Approved for the bridge Address to use them
    IERC721(tokenAddress).transferFrom(sender, address(this), tokenId);

    crossTokens(tokenAddress, to, tokenCreator, tokenId, destinationChainId, "");

    if (fixedFee == 0) {
      return;
    }
    uint256 msgValue = msg.value;
    require(msgValue >= fixedFee, "NFTBridge: value is smaller than fixed fee");

    // Send the payment to the MultiSig of the Federation
    federation.transfer(fixedFee);

    if (msgValue > fixedFee) { // refund of unused value
      sender.transfer(msgValue.sub(fixedFee));
    }
  }

  function crossTokens(
    address tokenAddress,
    address to,
    address tokenCreator,
    uint256 tokenId,
    uint256 destinationChainId,
    bytes memory userData
  ) internal whenNotUpgrading whenNotPaused nonReentrant {
    require(block.chainid != destinationChainId, "NFTBridge: destination chain id equal current chain id");
    _setAddressFromCrossedOriginalToken(destinationChainId, tokenAddress, true);

    string memory tokenURI = IERC721Metadata(tokenAddress).tokenURI(tokenId);

    OriginalNft memory originalToken = getOriginalTokenBySideToken(tokenAddress);
    address originalTokenAddress = tokenAddress;
    if (originalToken.nftAddress != NULL_ADDRESS) {
      ERC721Burnable(tokenAddress).burn(tokenId);
      originalTokenAddress = originalToken.nftAddress;
    }

    uint256 totalSupply = IERC721Enumerable(tokenAddress).totalSupply();
    emit Cross(
      originalTokenAddress,
      to,
      destinationChainId,
      _msgSender(),
      block.chainid,
      tokenCreator,
      totalSupply,
      tokenId,
      tokenURI,
      userData
    );
  }

  function getTransactionDataHash(
    address _to,
    address _from,
    uint256 _tokenId,
    address _tokenAddress,
    bytes32 _blockHash,
    bytes32 _transactionHash,
    uint32 _logIndex,
    uint256 _originChainId,
	  uint256	_destinationChainId
  ) public pure override returns (bytes32) {
    return keccak256(
      abi.encodePacked(
        _blockHash,
        _transactionHash,
        _to,
        _from,
        _tokenId,
        _tokenAddress,
        _logIndex,
        _originChainId,
        _destinationChainId
      )
    );
  }

  function setFixedFee(uint256 amount) external onlyOwner {
    fixedFee = amount;
    emit FixedFeeNFTChanged(fixedFee);
  }

  function getFixedFee() external view override returns (uint256) {
    return fixedFee;
  }

  function changeFederation(address payable newFederation) external onlyOwner {
    require(newFederation != NULL_ADDRESS, "NFTBridge: Federation is empty");
    federation = newFederation;
    emit FederationChanged(federation);
  }

  function changeAllowTokens(address newAllowTokens) external onlyOwner {
    require(newAllowTokens != NULL_ADDRESS, "NFTBridge: AllowTokens is empty");
    allowTokens = IAllowTokens(newAllowTokens);
    emit AllowTokensChanged(newAllowTokens);
  }

  function getFederation() external view returns (address) {
    return federation;
  }

  function changeSideTokenFactory(address newSideNFTTokenFactory) external onlyOwner {
    require(
      newSideNFTTokenFactory != NULL_ADDRESS,
      "NFTBridge: empty SideTokenFactory"
    );
    sideTokenFactory = ISideNFTTokenFactory(newSideNFTTokenFactory);
    emit SideTokenFactoryChanged(newSideNFTTokenFactory);
  }

  function setUpgrading(bool _isUpgrading) external onlyOwner {
    isUpgrading = _isUpgrading;
    emit Upgrading(isUpgrading);
  }

  function hasCrossed(bytes32 transactionHash) public view returns (bool) {
    return transactionDataHashes[transactionHash] != bytes32(0);
  }

  function hasBeenClaimed(bytes32 transactionHash) public view returns (bool) {
    return claimed[transactionDataHashes[transactionHash]];
  }

  /**
    * Always returns `IERC721Receiver.onERC721Received.selector`.
    */
  function onERC721Received(
    address,
    address,
    uint256,
    bytes memory
  ) public virtual override returns (bytes4) {
    return this.onERC721Received.selector;
  }

}
