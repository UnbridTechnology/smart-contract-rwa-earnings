// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "@openzeppelin/contracts@5.0.0/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "./UnbridRWAProsperityNFT.sol";

/**
 * @title Unbrid Earnings Manager
 * @dev Manages deposits, withdrawals, and earnings distribution
 */
contract UnbridRWAEarningsManagerV2 is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    UnbridRWAProsperityNFT public immutable nftContract;

    mapping(address => uint256) public totalEarningsByToken;
    mapping(uint256 => mapping(address => uint256))
        public claimedEarningsByToken;
    mapping(uint256 => uint256) public claimedEarningsMatic;

    mapping(address => mapping(address => uint256))
        public totalEarningsByUserAndToken;
    mapping(address => uint256) public totalMaticEarningsByUser;

    uint256 public totalEarningsMatic;

    // Almacenar los IDs de los NFTs elegibles en el momento del depósito
    mapping(address => uint256[]) public eligibleNFTsForTokenDeposit;
    mapping(uint256 => bool) public isNFTEligibleForTokenDeposit;

    // Declarar un contador para identificar cada depósito
    uint256 public maticDepositCounter;

    // Mapeo para almacenar los NFTs elegibles por depósito
    mapping(uint256 => uint256[]) public eligibleNFTsForMaticDeposit;

    // Mapeo para verificar si un NFT es elegible para un depósito específico
    mapping(uint256 => mapping(uint256 => bool))
        public isNFTEligibleForMaticDeposit;

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

    mapping(address => uint256) public totalWeightSnapshotForTokenDeposit;
    mapping(uint256 => uint256) public totalWeightSnapshotForMaticDeposit;

    constructor(address initialOwner, address _nftContractAddress)
        Ownable(initialOwner)
    {
        nftContract = UnbridRWAProsperityNFT(_nftContractAddress);
    }

    /**
     * @dev Deposits earnings in ERC-20 tokens
     * @param amount Amount of tokens to deposit
     * @param erc20Token ERC-20 token address
     */
    function depositEarnings(uint256 amount, address erc20Token)
        external
        nonReentrant
    {
        require(amount > 0, "Amount must be greater than 0");
        require(erc20Token != address(0), "Invalid ERC-20 token address");

        IERC20 token = IERC20(erc20Token);
        require(
            token.transferFrom(msg.sender, address(this), amount),
            "Token deposit failed"
        );

        totalEarningsByToken[erc20Token] += amount;

        // Tomar un snapshot del peso total en este momento
        totalWeightSnapshotForTokenDeposit[erc20Token] = calculateTotalWeight();

        emit EarningsDeposited(msg.sender, erc20Token, amount);
    }

    /**
     * @dev Deposits earnings in Matic
     */
    function depositEarningsMatic() external payable nonReentrant {
        require(msg.value > 0, "Amount must be greater than 0");

        totalEarningsMatic += msg.value;

        // Tomar un snapshot del peso total en este momento
        totalWeightSnapshotForMaticDeposit[
            maticDepositCounter
        ] = calculateTotalWeight();

        emit EarningsDepositedMatic(msg.sender, msg.value);
    }

    /**
     * @dev Allows users to claim their earnings in ERC-20 tokens
     * @param erc20Token ERC-20 token address
     */
    function claimEarnings(address erc20Token) external nonReentrant {
        require(nftContract.balanceOf(msg.sender) > 0, "No NFTs owned");

        uint256 totalTokenEarnings = totalEarningsByToken[erc20Token];
        require(totalTokenEarnings > 0, "No earnings available");

        uint256 totalWeight = calculateTotalWeight();
        require(totalWeight > 0, "Invalid total weight");

        uint256 scalingFactor = 10000;
        uint256 totalClaimableAmount = 0;

        for (uint256 i = 0; i < nftContract.balanceOf(msg.sender); i++) {
            uint256 tokenId = nftContract.tokenOfOwnerByIndex(msg.sender, i);

            // Verificar si el NFT era elegible en el momento del depósito
            if (isNFTEligibleForTokenDeposit[tokenId]) {
                uint256 earnings = calculateSingleNFTClaim( // Usar la función que modifica el estado
                    tokenId,
                    totalTokenEarnings,
                    totalWeight,
                    scalingFactor,
                    erc20Token
                );
                totalClaimableAmount += earnings;
            }
        }

        require(totalClaimableAmount > 0, "No rewards to claim");

        IERC20 token = IERC20(erc20Token);
        require(
            token.transfer(msg.sender, totalClaimableAmount),
            "Token transfer failed"
        );

        totalEarningsByUserAndToken[msg.sender][
            erc20Token
        ] += totalClaimableAmount;

        emit EarningsClaimed(msg.sender, erc20Token, totalClaimableAmount);
    }

    /**
     * @dev Allows the owner to claim earnings in Matic
     */
    function claimEarningsMatic() external nonReentrant {
        require(nftContract.balanceOf(msg.sender) > 0, "No NFTs owned");

        uint256 totalMaticEarnings = totalEarningsMatic;
        require(totalMaticEarnings > 0, "No Matic earnings available");

        uint256 totalWeight = calculateTotalWeight();
        require(totalWeight > 0, "Invalid total weight");

        uint256 totalClaimableAmount = 0;

        for (uint256 i = 0; i < nftContract.balanceOf(msg.sender); i++) {
            uint256 tokenId = nftContract.tokenOfOwnerByIndex(msg.sender, i);

            // Verificar si el NFT era elegible en el momento del depósito
            if (isNFTEligibleForMaticDeposit[maticDepositCounter][tokenId]) {
                uint256 pendingEarnings = calculatePendingEarningsMatic(
                    tokenId,
                    totalMaticEarnings,
                    totalWeight
                );
                totalClaimableAmount += pendingEarnings;
                claimedEarningsMatic[tokenId] += pendingEarnings;
            }
        }

        require(totalClaimableAmount > 0, "No rewards to claim");

        (bool success, ) = msg.sender.call{value: totalClaimableAmount}("");
        require(success, "Matic transfer failed");

        totalMaticEarningsByUser[msg.sender] += totalClaimableAmount;

        emit MaticEarningsClaimed(msg.sender, totalClaimableAmount);
    }

    /**
     * @dev Calculates the total weight of all NFTs in circulation
     * @return totalWeight Total weight of all NFTs
     */
    function calculateTotalWeight()
        internal
        view
        returns (uint256 totalWeight)
    {
        for (uint256 i = 0; i < nftContract.totalSupply(); i++) {
            uint256 tokenId = nftContract.tokenByIndex(i);
            totalWeight +=
                nftContract.getTypeMultiplier(nftContract.nftTypes(tokenId)) *
                nftContract.getStagePercentage(nftContract.mintStages(tokenId));
        }
    }

    /**
     * @dev Calculates the pending earnings for a single NFT
     * @param tokenId ID of the NFT
     * @param totalTokenEarnings Total earnings in the token
     * @param totalWeight Total weight of all NFTs
     * @param scalingFactor Scaling factor for precision
     * @param erc20Token ERC-20 token address
     * @return pendingEarnings Earnings pending to be claimed
     */
    function calculateSingleNFTClaim(
        uint256 tokenId,
        uint256 totalTokenEarnings,
        uint256 totalWeight,
        uint256 scalingFactor,
        address erc20Token
    ) internal returns (uint256) {
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
            claimedEarningsByToken[tokenId][erc20Token] += pendingEarnings;
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
     * @dev Allows the owner to withdraw funds
     * @param to Address to withdraw to
     * @param amount Amount to withdraw
     * @param erc20Token ERC-20 token address
     */
    function withdraw(
        address to,
        uint256 amount,
        address erc20Token
    ) external onlyOwner nonReentrant {
        if (erc20Token == address(0)) {
            require(
                address(this).balance >= amount,
                "Insufficient Matic balance"
            );
            (bool success, ) = to.call{value: amount}("");
            require(success, "Matic withdrawal failed");
        } else {
            IERC20 token = IERC20(erc20Token);
            require(
                token.balanceOf(address(this)) >= amount,
                "Insufficient token balance"
            );
            token.safeTransfer(to, amount);
        }
        emit Withdrawn(to, amount);
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
     * @dev Función de inicialización para marcar todos los NFTs existentes como elegibles.
     * Solo puede ser llamada por el propietario del contrato.
     */
    function initializeEligibleNFTs() external onlyOwner {
        uint256 totalSupply = nftContract.totalSupply();

        // Marcar todos los NFTs existentes como elegibles para tokens ERC-20
        for (uint256 i = 0; i < totalSupply; i++) {
            uint256 tokenId = nftContract.tokenByIndex(i);
            isNFTEligibleForTokenDeposit[tokenId] = true;
        }

        // Marcar todos los NFTs existentes como elegibles para Matic
        for (uint256 i = 0; i < totalSupply; i++) {
            uint256 tokenId = nftContract.tokenByIndex(i);
            isNFTEligibleForMaticDeposit[maticDepositCounter][tokenId] = true;
        }
    }

    /**
     * @dev Marca como elegibles los NFTs que aún no han sido marcados.
     * Solo puede ser llamada por el propietario del contrato.
     */
    function markUnmarkedNFTsAsEligible() external onlyOwner {
        uint256 totalSupply = nftContract.totalSupply();

        for (uint256 i = 0; i < totalSupply; i++) {
            uint256 tokenId = nftContract.tokenByIndex(i);

            // Marcar el NFT como elegible para tokens ERC-20 si no lo está
            if (!isNFTEligibleForTokenDeposit[tokenId]) {
                isNFTEligibleForTokenDeposit[tokenId] = true;
            }

            // Marcar el NFT como elegible para Matic si no lo está
            if (!isNFTEligibleForMaticDeposit[maticDepositCounter][tokenId]) {
                isNFTEligibleForMaticDeposit[maticDepositCounter][
                    tokenId
                ] = true;
            }
        }
    }
}
