// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "@openzeppelin/contracts@5.0.0/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "./UnbridRWAProsperityNFT.sol";

/**
 * @title Unbrid Earnings Manager V3
 * @dev NFTs
 */
contract UnbridRWAEarningsManagerV3 is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    UnbridRWAProsperityNFT public immutable nftContract;

    uint256 public stage1Multiplier = 150; // 1.5x
    uint256 public stage2Multiplier = 130; // 1.3x
    uint256 public stage3Multiplier = 120; // 1.2x
    uint256 public stage4Multiplier = 110; // 1.1x
    uint256 public stage5Multiplier = 105; // 1.05x

    mapping(uint256 => uint256) public typeMultipliers; // NFTType -> multiplier

    mapping(address => uint256) public totalEarningsByToken;
    mapping(uint256 => mapping(address => uint256))
        public claimedEarningsByToken;
    mapping(uint256 => uint256) public claimedEarningsMatic;
    mapping(address => mapping(address => uint256))
        public totalEarningsByUserAndToken;
    mapping(address => uint256) public totalMaticEarningsByUser;
    uint256 public totalEarningsMatic;

    mapping(uint256 => bool) public isNFTEligibleForTokenDeposit;
    mapping(uint256 => bool) public nftBlockedForToken;
    mapping(uint256 => bool) public nftBlockedForMatic;
    mapping(uint256 => bool) public nftBlockedForAll;

    uint256 public maticDepositCounter;
    mapping(uint256 => uint256[]) public eligibleNFTsForMaticDeposit;
    mapping(uint256 => mapping(uint256 => bool))
        public isNFTEligibleForMaticDeposit;

    mapping(address => uint256) public totalWeightSnapshotForTokenDeposit;
    mapping(uint256 => uint256) public totalWeightSnapshotForMaticDeposit;

    event EarningsDeposited(
        address indexed depositor,
        address indexed erc20Token,
        uint256 amount
    );
    event EarningsDepositedMatic(address indexed depositor, uint256 amount);
    event EarningsClaimed(
        address indexed user,
        address indexed erc20Token,
        uint256 amount
    );
    event MaticEarningsClaimed(address indexed user, uint256 amount);
    event Withdrawn(address indexed to, uint256 amount);
    event NFTBlockStatusChanged(
        uint256 tokenId,
        bool tokenBlocked,
        bool maticBlocked,
        bool allBlocked
    );
    event MultipliersUpdated(
        uint256 newSilver,
        uint256 newGold,
        uint256 newSapphire,
        uint256 newEmerald,
        uint256 newDiamond
    );
    event StageMultipliersUpdated(
        uint256 stage1,
        uint256 stage2,
        uint256 stage3,
        uint256 stage4,
        uint256 stage5
    );

    constructor(address initialOwner, address _nftContractAddress)
        Ownable(initialOwner)
    {
        nftContract = UnbridRWAProsperityNFT(_nftContractAddress);

        // (1x, 5x, 10x, 25x, 50x)
        typeMultipliers[uint256(UnbridRWAProsperityNFT.NFTType.SILVER)] = 1;
        typeMultipliers[uint256(UnbridRWAProsperityNFT.NFTType.GOLD)] = 5;
        typeMultipliers[uint256(UnbridRWAProsperityNFT.NFTType.SAPPHIRE)] = 10;
        typeMultipliers[uint256(UnbridRWAProsperityNFT.NFTType.EMERALD)] = 25;
        typeMultipliers[uint256(UnbridRWAProsperityNFT.NFTType.DIAMOND)] = 50;
    }

    function setTypeMultipliers(
        uint256 silverMultiplier,
        uint256 goldMultiplier,
        uint256 sapphireMultiplier,
        uint256 emeraldMultiplier,
        uint256 diamondMultiplier
    ) external onlyOwner {
        typeMultipliers[
            uint256(UnbridRWAProsperityNFT.NFTType.SILVER)
        ] = silverMultiplier;
        typeMultipliers[
            uint256(UnbridRWAProsperityNFT.NFTType.GOLD)
        ] = goldMultiplier;
        typeMultipliers[
            uint256(UnbridRWAProsperityNFT.NFTType.SAPPHIRE)
        ] = sapphireMultiplier;
        typeMultipliers[
            uint256(UnbridRWAProsperityNFT.NFTType.EMERALD)
        ] = emeraldMultiplier;
        typeMultipliers[
            uint256(UnbridRWAProsperityNFT.NFTType.DIAMOND)
        ] = diamondMultiplier;

        emit MultipliersUpdated(
            silverMultiplier,
            goldMultiplier,
            sapphireMultiplier,
            emeraldMultiplier,
            diamondMultiplier
        );
    }

    /**
     * @dev stages
     */
    function setStageMultipliers(
        uint256 _stage1,
        uint256 _stage2,
        uint256 _stage3,
        uint256 _stage4,
        uint256 _stage5
    ) external onlyOwner {
        stage1Multiplier = _stage1;
        stage2Multiplier = _stage2;
        stage3Multiplier = _stage3;
        stage4Multiplier = _stage4;
        stage5Multiplier = _stage5;

        emit StageMultipliersUpdated(
            _stage1,
            _stage2,
            _stage3,
            _stage4,
            _stage5
        );
    }

    /**
     * @dev NFts
     */
    function setNFTBlockStatus(
        uint256 tokenId,
        bool blockToken,
        bool blockMatic,
        bool blockAll
    ) external onlyOwner {
        require(nftContract.ownerOf(tokenId) != address(0), "NFT not found");

        if (blockAll) {
            nftBlockedForAll[tokenId] = true;
            nftBlockedForToken[tokenId] = true;
            nftBlockedForMatic[tokenId] = true;
        } else {
            if (blockToken) nftBlockedForToken[tokenId] = true;
            if (blockMatic) nftBlockedForMatic[tokenId] = true;
        }

        emit NFTBlockStatusChanged(tokenId, blockToken, blockMatic, blockAll);
    }

    function unblockNFT(uint256 tokenId) external onlyOwner {
        require(
            nftBlockedForAll[tokenId] ||
                nftBlockedForToken[tokenId] ||
                nftBlockedForMatic[tokenId],
            "NFT unbloked"
        );

        nftBlockedForAll[tokenId] = false;
        nftBlockedForToken[tokenId] = false;
        nftBlockedForMatic[tokenId] = false;

        emit NFTBlockStatusChanged(tokenId, false, false, false);
    }

    function depositEarnings(uint256 amount, address erc20Token)
        external
        nonReentrant
    {
        require(amount > 0, "Amount > 0");
        require(erc20Token != address(0), "Invalid Token");

        IERC20(erc20Token).safeTransferFrom(msg.sender, address(this), amount);
        totalEarningsByToken[erc20Token] += amount;
        totalWeightSnapshotForTokenDeposit[erc20Token] = calculateTotalWeight();

        emit EarningsDeposited(msg.sender, erc20Token, amount);
    }

    function depositEarningsMatic() external payable nonReentrant {
        require(msg.value > 0, "Amount > 0");

        totalEarningsMatic += msg.value;
        totalWeightSnapshotForMaticDeposit[
            maticDepositCounter
        ] = calculateTotalWeight();
        maticDepositCounter++;

        emit EarningsDepositedMatic(msg.sender, msg.value);
    }

    function claimEarnings(address erc20Token) external nonReentrant {
        require(nftContract.balanceOf(msg.sender) > 0, "Dont Have NFTs");
        require(totalEarningsByToken[erc20Token] > 0, "No Earnings");

        uint256 totalWeight = totalWeightSnapshotForTokenDeposit[erc20Token];
        require(totalWeight > 0, "Invalid Total Weight");

        uint256 totalClaimable;
        for (uint256 i = 0; i < nftContract.balanceOf(msg.sender); i++) {
            uint256 tokenId = nftContract.tokenOfOwnerByIndex(msg.sender, i);

            if (!isNFTEligible(tokenId, false)) continue;

            totalClaimable += _calculateClaim(
                tokenId,
                erc20Token,
                totalWeight,
                false
            );
        }

        require(totalClaimable > 0, "Nothing By Claim");
        IERC20(erc20Token).safeTransfer(msg.sender, totalClaimable);
        totalEarningsByUserAndToken[msg.sender][erc20Token] += totalClaimable;

        emit EarningsClaimed(msg.sender, erc20Token, totalClaimable);
    }

    function claimEarningsMatic() external nonReentrant {
        require(nftContract.balanceOf(msg.sender) > 0, "Dont have NFTs");
        require(totalEarningsMatic > 0, "No MATIC Earnings");

        uint256 totalWeight = totalWeightSnapshotForMaticDeposit[
            maticDepositCounter - 1
        ];
        require(totalWeight > 0, "Invalid Total Weight");

        uint256 totalClaimable;
        for (uint256 i = 0; i < nftContract.balanceOf(msg.sender); i++) {
            uint256 tokenId = nftContract.tokenOfOwnerByIndex(msg.sender, i);

            if (!isNFTEligible(tokenId, true)) continue;

            totalClaimable += _calculateClaim(
                tokenId,
                address(0),
                totalWeight,
                true
            );
        }

        require(totalClaimable > 0, "Nothing By Claim");
        (bool success, ) = msg.sender.call{value: totalClaimable}("");
        require(success, "Failed Transfer");
        totalMaticEarningsByUser[msg.sender] += totalClaimable;

        emit MaticEarningsClaimed(msg.sender, totalClaimable);
    }

    function calculateTotalWeight() public view returns (uint256) {
        uint256 totalWeight;
        uint256 totalSupply = nftContract.totalSupply();

        for (uint256 i = 0; i < totalSupply; i++) {
            uint256 tokenId = nftContract.tokenByIndex(i);
            UnbridRWAProsperityNFT.NFTType nftType = nftContract.nftTypes(
                tokenId
            );
            uint8 stage = nftContract.mintStages(tokenId);

            totalWeight += getNFTWeight(tokenId, nftType, stage);
        }
        return totalWeight;
    }

    function getNFTWeight(
        uint256 tokenId,
        UnbridRWAProsperityNFT.NFTType nftType,
        uint8 stage
    ) public view returns (uint256) {
        if (nftBlockedForAll[tokenId]) return 0;

        uint256 typeMult = typeMultipliers[uint256(nftType)];
        uint256 stageMult = getStageMultiplier(stage);

        return typeMult * stageMult;
    }

    function getStageMultiplier(uint8 stage) public view returns (uint256) {
        if (stage == 1) return stage1Multiplier;
        if (stage == 2) return stage2Multiplier;
        if (stage == 3) return stage3Multiplier;
        if (stage == 4) return stage4Multiplier;
        if (stage == 5) return stage5Multiplier;
        return 100; // 1x default
    }

    function isNFTEligible(uint256 tokenId, bool forMatic)
        public
        view
        returns (bool)
    {
        if (nftBlockedForAll[tokenId]) return false;

        if (forMatic) {
            return
                !nftBlockedForMatic[tokenId] &&
                isNFTEligibleForMaticDeposit[maticDepositCounter - 1][tokenId];
        } else {
            return
                !nftBlockedForToken[tokenId] &&
                isNFTEligibleForTokenDeposit[tokenId];
        }
    }

    function _calculateClaim(
        uint256 tokenId,
        address erc20Token,
        uint256 totalWeight,
        bool isMatic
    ) internal returns (uint256) {
        UnbridRWAProsperityNFT.NFTType nftType = nftContract.nftTypes(tokenId);
        uint8 stage = nftContract.mintStages(tokenId);

        uint256 nftWeight = getNFTWeight(tokenId, nftType, stage);
        uint256 earningsShare = (nftWeight * 1e18) / totalWeight; // Alta precisión

        uint256 totalEarnings = isMatic
            ? totalEarningsMatic
            : totalEarningsByToken[erc20Token];
        uint256 nftEarnings = (totalEarnings * earningsShare) / 1e18;

        uint256 claimed = isMatic
            ? claimedEarningsMatic[tokenId]
            : claimedEarningsByToken[tokenId][erc20Token];
        uint256 claimable = nftEarnings > claimed ? nftEarnings - claimed : 0;

        if (claimable > 0) {
            if (isMatic) {
                claimedEarningsMatic[tokenId] += claimable;
            } else {
                claimedEarningsByToken[tokenId][erc20Token] += claimable;
            }
        }

        return claimable;
    }

    function initializeEligibleNFTs() external onlyOwner {
        uint256 totalSupply = nftContract.totalSupply();

        for (uint256 i = 0; i < totalSupply; i++) {
            uint256 tokenId = nftContract.tokenByIndex(i);
            if (!nftBlockedForAll[tokenId]) {
                isNFTEligibleForTokenDeposit[tokenId] = true;
                isNFTEligibleForMaticDeposit[maticDepositCounter][
                    tokenId
                ] = true;
            }
        }
    }

    function markUnmarkedNFTsAsEligible() external onlyOwner {
        uint256 totalSupply = nftContract.totalSupply();

        for (uint256 i = 0; i < totalSupply; i++) {
            uint256 tokenId = nftContract.tokenByIndex(i);

            if (!nftBlockedForAll[tokenId]) {
                if (
                    !isNFTEligibleForTokenDeposit[tokenId] &&
                    !nftBlockedForToken[tokenId]
                ) {
                    isNFTEligibleForTokenDeposit[tokenId] = true;
                }

                if (
                    !isNFTEligibleForMaticDeposit[maticDepositCounter][
                        tokenId
                    ] && !nftBlockedForMatic[tokenId]
                ) {
                    isNFTEligibleForMaticDeposit[maticDepositCounter][
                        tokenId
                    ] = true;
                }
            }
        }
    }

    function withdraw(
        address to,
        uint256 amount,
        address erc20Token
    ) external onlyOwner nonReentrant {
        if (erc20Token == address(0)) {
            (bool success, ) = to.call{value: amount}("");
            require(success, "Failed Transfer");
        } else {
            IERC20(erc20Token).safeTransfer(to, amount);
        }
        emit Withdrawn(to, amount);
    }

    /**
     * @dev Function to get the tokenIds of the NFTs owned by a user.
     * @param user Address of the user whose token list is desired.
     * @return An array of tokenIds owned by the user.
     */
    function getUserTokens(address user)
        public
        view
        returns (uint256[] memory)
    {
        uint256 balance = nftContract.balanceOf(user);
        uint256[] memory tokenIds = new uint256[](balance);

        for (uint256 i = 0; i < balance; i++) {
            tokenIds[i] = nftContract.tokenOfOwnerByIndex(user, i);
        }

        return tokenIds;
    }

    /**
     * @dev Get the total accumulated earnings of a user for an ERC-20 token
     * @param user Address of the user
     * @param erc20Token Address of the ERC-20 token
     * @return totalEarnings Total accumulated earnings
     */
    function getTotalEarningsByUser(address user, address erc20Token)
        external
        view
        returns (uint256 totalEarnings)
    {
        return totalEarningsByUserAndToken[user][erc20Token];
    }

    /**
     * @dev Get the total accumulated earnings of a user in Matic
     * @param user Address of the user
     * @return totalEarnings Total accumulated earnings in Matic
     */
    function getTotalMaticEarningsByUser(address user)
        external
        view
        returns (uint256 totalEarnings)
    {
        return totalMaticEarningsByUser[user];
    }

    function calculateSingleNFTClaimView(
        uint256 tokenId,
        uint256 totalTokenEarnings,
        uint256 totalWeight,
        uint256 scalingFactor,
        address erc20Token
    ) internal view returns (uint256) {
        uint256 typeMultiplier = nftContract.getTypeMultiplier(
            nftContract.nftTypes(tokenId)
        );
        uint256 stagePercentage = nftContract.getStagePercentage(
            nftContract.mintStages(tokenId)
        );

        uint256 nftWeight = typeMultiplier * stagePercentage;
        uint256 userShare = (nftWeight * scalingFactor) / totalWeight;

        uint256 tokenEarnings = (totalTokenEarnings * userShare) /
            scalingFactor;
        uint256 claimedEarnings = claimedEarningsByToken[tokenId][erc20Token];

        uint256 pendingEarnings = 0;
        if (tokenEarnings > claimedEarnings) {
            pendingEarnings = tokenEarnings - claimedEarnings;
        }

        return pendingEarnings;
    }

    /**
     * @dev Calculates the pending earnings for a single NFT in Matic
     * @param tokenId ID of the NFT
     * @param totalMaticEarnings Total earnings in Matic
     * @param totalWeight Total weight of all NFTs
     * @return pendingEarnings Earnings pending to be claimed
     */
    function calculatePendingEarningsMatic(
        uint256 tokenId,
        uint256 totalMaticEarnings,
        uint256 totalWeight
    ) internal view returns (uint256 pendingEarnings) {
        uint256 typeMultiplier = nftContract.getTypeMultiplier(
            nftContract.nftTypes(tokenId)
        );
        uint256 stagePercentage = nftContract.getStagePercentage(
            nftContract.mintStages(tokenId)
        );

        uint256 nftWeight = typeMultiplier * stagePercentage;

        uint256 scalingFactor = 10000;
        uint256 userShare = (nftWeight * scalingFactor) / totalWeight;

        uint256 maticEarnings = (totalMaticEarnings * userShare) /
            scalingFactor;

        uint256 claimed = claimedEarningsMatic[tokenId];
        if (maticEarnings > claimed) {
            pendingEarnings = maticEarnings - claimed;
        } else {
            pendingEarnings = 0;
        }
    }

    /**
     * @dev Allows a user to check pending earnings in an ERC-20 token
     * @param user Address to check
     * @param erc20Token ERC-20 token address
     * @return Amount of pending earnings in the ERC-20 token
     */
    function getPendingEarnings(address user, address erc20Token)
        external
        view
        returns (uint256)
    {
        require(nftContract.balanceOf(user) > 0, "No NFTs owned");
        uint256 totalTokenEarnings = totalEarningsByToken[erc20Token];
        if (totalTokenEarnings == 0) return 0;

        // Usar el snapshot del peso total en lugar de recalcularlo
        uint256 totalWeight = totalWeightSnapshotForTokenDeposit[erc20Token];
        require(totalWeight > 0, "Invalid total weight");

        uint256 scalingFactor = 10000;
        uint256 totalClaimableAmount = 0;

        for (uint256 i = 0; i < nftContract.balanceOf(user); i++) {
            uint256 tokenId = nftContract.tokenOfOwnerByIndex(user, i);

            // Verificar si el NFT era elegible en el momento del depósito
            if (isNFTEligibleForTokenDeposit[tokenId]) {
                totalClaimableAmount += calculateSingleNFTClaimView(
                    tokenId,
                    totalTokenEarnings,
                    totalWeight,
                    scalingFactor,
                    erc20Token
                );
            }
        }

        return totalClaimableAmount;
    }

    /**
     * @dev Allows a user to check pending earnings in Matic
     * @param user Address to check
     * @return Amount of pending earnings in Matic
     */
    function getPendingEarningsMatic(address user)
        external
        view
        returns (uint256)
    {
        require(nftContract.balanceOf(user) > 0, "No NFTs owned");

        uint256 totalMaticEarnings = totalEarningsMatic;
        if (totalMaticEarnings == 0) return 0;

        // Usar el snapshot del peso total en lugar de recalcularlo
        uint256 totalWeight = totalWeightSnapshotForMaticDeposit[
            maticDepositCounter
        ];
        require(totalWeight > 0, "Invalid total weight");

        uint256 totalClaimableAmount = 0;
        for (uint256 i = 0; i < nftContract.balanceOf(user); i++) {
            uint256 tokenId = nftContract.tokenOfOwnerByIndex(user, i);

            // Verificar si el NFT era elegible en el momento del depósito
            if (isNFTEligibleForMaticDeposit[maticDepositCounter][tokenId]) {
                uint256 typeMultiplier = nftContract.getTypeMultiplier(
                    nftContract.nftTypes(tokenId)
                );
                uint256 stagePercentage = nftContract.getStagePercentage(
                    nftContract.mintStages(tokenId)
                );

                uint256 nftWeight = typeMultiplier * stagePercentage;

                uint256 nftEarnings = (totalMaticEarnings * nftWeight) /
                    totalWeight;

                uint256 pendingEarnings = nftEarnings -
                    claimedEarningsMatic[tokenId];
                totalClaimableAmount += pendingEarnings;
            }
        }

        return totalClaimableAmount;
    }
}
