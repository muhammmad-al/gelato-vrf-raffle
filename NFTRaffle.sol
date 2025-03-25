// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

/**
 * @title IGelatoVRFConsumer
 * @dev Interface for consuming random number provided by Gelato VRF
 */
interface IGelatoVRFConsumer {
    event RequestedRandomness(uint256 round, bytes data);
    
    function fulfillRandomness(
        uint256 randomness,
        bytes calldata data
    ) external;
}

/**
 * @title GelatoVRFConsumerBase
 * @dev Base contract for Gelato VRF consumers
 */
abstract contract GelatoVRFConsumerBase is IGelatoVRFConsumer {
    // Constants used for the Gelato VRF service
    uint256 private constant _PERIOD = 3;
    uint256 private constant _GENESIS = 1692803367;
    bool[] public requestPending;
    mapping(uint256 => bytes32) public requestedHash;

    /// @notice Returns the address of the dedicated msg.sender.
    function _operator() internal view virtual returns (address);

    /// @notice User logic to handle the random value received.
    function _fulfillRandomness(
        uint256 randomness,
        uint256 requestId,
        bytes memory extraData
    ) internal virtual;

    /// @notice Requests randomness from the Gelato VRF.
    function _requestRandomness(
        bytes memory extraData
    ) internal returns (uint256 requestId) {
        requestId = uint256(requestPending.length);
        requestPending.push();
        requestPending[requestId] = true;

        bytes memory data = abi.encode(requestId, extraData);
        uint256 round = _round();

        bytes memory dataWithRound = abi.encode(round, data);
        bytes32 requestHash = keccak256(dataWithRound);

        requestedHash[requestId] = requestHash;

        emit RequestedRandomness(round, data);
    }

    /// @notice Callback function used by Gelato VRF to return the random number.
    function fulfillRandomness(
        uint256 randomness,
        bytes calldata dataWithRound
    ) external {
        require(msg.sender == _operator(), "only operator");

        (, bytes memory data) = abi.decode(dataWithRound, (uint256, bytes));
        (uint256 requestId, bytes memory extraData) = abi.decode(
            data,
            (uint256, bytes)
        );

        bytes32 requestHash = keccak256(dataWithRound);
        bool isValidRequestHash = requestHash == requestedHash[requestId];

        require(requestPending[requestId], "request fulfilled or missing");

        if (isValidRequestHash) {
            randomness = uint256(
                keccak256(
                    abi.encode(
                        randomness,
                        address(this),
                        block.chainid,
                        requestId
                    )
                )
            );

            _fulfillRandomness(randomness, requestId, extraData);
            requestPending[requestId] = false;
        }
    }

    /// @notice Computes and returns the round number of drand to request randomness from.
    function _round() private view returns (uint256 round) {
        uint256 elapsedFromGenesis = block.timestamp - _GENESIS;
        uint256 currentRound = (elapsedFromGenesis / _PERIOD) + 1;

        round = block.chainid == 1 ? currentRound + 4 : currentRound + 1;
    }
}

/**
 * @title Interface for the NFT contract
 */
interface INFT {
    function ownerOf(uint256 tokenId) external view returns (address);
    function totalSupply() external view returns (uint256);
    function supply() external view returns (uint256);
}

/**
 * @title NFTRaffle
 * @dev Contract that implements a raffle for NFT token IDs using Gelato VRF
 */
contract NFTRaffle is GelatoVRFConsumerBase {
    // Address of the NFT contract
    address public immutable nftContract;
    
    // Address of the Gelato VRF operator
    address public immutable gelatoOperator;
    
    // Owner of the raffle contract
    address public immutable owner;
    
    // Number of winners to select - now can be changed by owner
    uint256 public numWinners = 100;
    
    // Timestamp when minting is considered complete
    uint256 public mintingEndTime;
    
    // Raffle state variables
    bool public raffleExecuted;
    uint256 public randomnessRequestId;
    
    // Storage for winners
    uint256[] public winningTokenIds;
    address[] public winningAddresses;
    
    // Mapping to track selected tokens during raffle
    mapping(uint256 => bool) private selectedTokens;
    
    // Events
    event RaffleStarted(uint256 requestId);
    event RaffleCompleted(uint256[] winningTokenIds, address[] winningAddresses);
    event MintingEndTimeSet(uint256 endTime);
    event NumWinnersSet(uint256 newNumWinners);
    
    /**
     * @dev Constructor
     * @param _nftContract Address of the NFT contract
     * @param _gelatoOperator Address of the Gelato VRF operator
     * @param _mintingEndTime Timestamp when minting is considered complete
     */
    constructor(
        address _nftContract, 
        address _gelatoOperator,
        uint256 _mintingEndTime
    ) {
        require(_nftContract != address(0), "Invalid NFT contract address");
        require(_gelatoOperator != address(0), "Invalid Gelato operator address");
        require(_mintingEndTime > block.timestamp, "Minting end time must be in the future");
        
        nftContract = _nftContract;
        gelatoOperator = _gelatoOperator;
        mintingEndTime = _mintingEndTime;
        owner = msg.sender;
    }
    
    /**
     * @dev Modifier to restrict function access to the owner
     */
    modifier onlyOwner() {
        require(msg.sender == owner, "Caller is not the owner");
        _;
    }
    
    /**
     * @dev Implementation of _operator function from GelatoVRFConsumerBase
     */
    function _operator() internal view override returns (address) {
        return gelatoOperator;
    }
    
    /**
     * @dev Set the number of winners to select
     * @param _numWinners New number of winners
     */
    function setNumWinners(uint256 _numWinners) external onlyOwner {
        require(_numWinners > 0, "Number of winners must be greater than 0");
        require(!raffleExecuted, "Raffle already executed");
        
        numWinners = _numWinners;
        emit NumWinnersSet(_numWinners);
    }
    
    /**
     * @dev Set the timestamp when minting is considered complete
     * @param _mintingEndTime New minting end time
     */
    function setMintingEndTime(uint256 _mintingEndTime) external onlyOwner {
        require(_mintingEndTime > block.timestamp, "Minting end time must be in the future");
        require(!raffleExecuted, "Raffle already executed");
        
        mintingEndTime = _mintingEndTime;
        emit MintingEndTimeSet(_mintingEndTime);
    }
    
    /**
     * @dev Check if minting is complete based on block timestamp
     * @return isComplete True if minting is complete, false otherwise
     */
    function isMintingComplete() public view returns (bool) {
        return block.timestamp >= mintingEndTime;
    }
    
    /**
     * @dev Start the raffle
     * @return requestId The ID of the randomness request
     */
    function startRaffle() external onlyOwner returns (uint256 requestId) {
        require(!raffleExecuted, "Raffle already executed");
        require(isMintingComplete(), "Minting is not complete yet");
        
        // Additional check to ensure there are tokens to raffle
        uint256 totalSupply;
        bool hasTokens = false;
        
        try INFT(nftContract).supply() returns (uint256 supply) {
            totalSupply = supply;
            hasTokens = supply > 0;
        } catch {
            try INFT(nftContract).totalSupply() returns (uint256 supply) {
                totalSupply = supply;
                hasTokens = supply > 0;
            } catch {
                revert("Failed to get total supply");
            }
        }
        
        require(hasTokens, "No tokens available for raffle");
        
        // Request randomness with empty extraData
        requestId = _requestRandomness("");
        randomnessRequestId = requestId;
        
        emit RaffleStarted(requestId);
        return requestId;
    }
    
    /**
     * @dev Implementation of _fulfillRandomness from GelatoVRFConsumerBase
     */
    function _fulfillRandomness(
        uint256 randomness,
        uint256 requestId,
        bytes memory 
    ) internal override {
        require(requestId == randomnessRequestId, "Invalid request ID");
        require(!raffleExecuted, "Raffle already executed");
        
        // Get total supply to determine range of token IDs
        uint256 totalSupply;
        try INFT(nftContract).supply() returns (uint256 supply) {
            totalSupply = supply;
        } catch {
            try INFT(nftContract).totalSupply() returns (uint256 supply) {
                totalSupply = supply;
            } catch {
                revert("Failed to get total supply");
            }
        }
        
        require(totalSupply > 0, "No tokens minted");
        
        // Select winners
        selectWinners(randomness, totalSupply);
        
        // Mark raffle as executed
        raffleExecuted = true;
        
        emit RaffleCompleted(winningTokenIds, winningAddresses);
    }
    
    /**
     * @dev Select winners using the provided randomness
     * @param _seed Random seed to use for winner selection
     * @param _totalTokens Total number of tokens in the NFT contract
     */
    function selectWinners(uint256 _seed, uint256 _totalTokens) private {
        // Clear previous winners if any
        delete winningTokenIds;
        delete winningAddresses;
        
        // Clear the selected tokens mapping from any previous use
        for (uint256 i = 0; i < winningTokenIds.length; i++) {
            selectedTokens[winningTokenIds[i]] = false;
        }
        
        // Determine how many winners to select (up to numWinners)
        uint256 winnersToSelect = numWinners;
        if (_totalTokens < numWinners) {
            winnersToSelect = _totalTokens;
        }
        
        // Adjust token IDs based on ERC721A start index
        uint256 startTokenId = 1; // Token IDs typically start at 1
        
        // Select winners
        uint256 winnerCount = 0;
        uint256 nonce = 0;
        
        // Continue until we have enough winners or too many attempts
        while (winnerCount < winnersToSelect && nonce < _totalTokens * 2) {
            // Generate pseudo-random token ID between startTokenId and _totalTokens
            uint256 randomTokenId = startTokenId + (uint256(keccak256(abi.encode(_seed, nonce))) % _totalTokens);
            
            // Check if this token ID is already selected
            if (!selectedTokens[randomTokenId]) {
                try INFT(nftContract).ownerOf(randomTokenId) returns (address tokenOwner) {
                    // Mark token as selected
                    selectedTokens[randomTokenId] = true;
                    
                    // Add to winners list
                    winningTokenIds.push(randomTokenId);
                    winningAddresses.push(tokenOwner);
                    
                    winnerCount++;
                } catch {
                    // Skip tokens that don't exist or have issues
                }
            }
            
            // Increment nonce for next attempt
            nonce++;
        }
    }
    
    /**
     * @dev Get the list of winning token IDs
     * @return Array of winning token IDs
     */
    function getWinningTokenIds() external view returns (uint256[] memory) {
        require(raffleExecuted, "Raffle not executed yet");
        return winningTokenIds;
    }
    
    /**
     * @dev Get the list of winning addresses
     * @return Array of addresses that own the winning tokens
     */
    function getWinningAddresses() external view returns (address[] memory) {
        require(raffleExecuted, "Raffle not executed yet");
        return winningAddresses;
    }
    
    /**
     * @dev Get both winning token IDs and their owners
     * @return tokenIds Array of winning token IDs
     * @return owners Array of addresses that own the winning tokens
     */
    function getRaffleResults() external view returns (uint256[] memory tokenIds, address[] memory owners) {
        require(raffleExecuted, "Raffle not executed yet");
        return (winningTokenIds, winningAddresses);
    }
}