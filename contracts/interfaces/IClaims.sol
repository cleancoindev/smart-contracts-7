// SPDX-License-Identifier: GPL-3.0-only

pragma solidity >=0.5.0;

import "@openzeppelin/contracts-v4/token/ERC721/IERC721Receiver.sol";

interface IClaims {

  /* ========== DATA STRUCTURES ========== */

  enum ClaimStatus { PENDING, ACCEPTED, DENIED }

  enum PayoutStatus { PENDING, COMPLETE, UNCLAIMED, DENIED }

  enum UintParams {
    payoutRedemptionPeriodDays,
    minAssessmentDepositRatio,
    maxRewardNXM,
    rewardRatio
  }

  struct Configuration {
    // Number of days in which payouts can be redeemed
    uint8 payoutRedemptionPeriodDays;

    // Ratio out of 1 ETH, used to calculate a flat ETH deposit required for claim submission.
    // If the claim is accepted, the user will receive the deposit back when the payout is redeemed.
    // (0-10000 bps i.e. double decimal precision)
    uint16 minAssessmentDepositRatio;

    // An amount of NXM representing the maximum reward amount given for any claim assessment.
    uint16 maxRewardNXM;

    // Ratio used to calculate assessment rewards. (0-10000 i.e. double decimal precision).
    uint16 rewardRatio;
  }

  /*
   *  Holds the requested amount, NXM price, submission fee and other relevant details
   *  such as parts of the corresponding cover details and the payout status.
   *
   *  This structure has snapshots of claim-time states that are considered moving targets
   *  but also parts of cover details that reduce the need of external calls. Everything is fitted
   *  in a single word that contains:
   */
  struct Claim {
    // The index of the assessment, stored in Assessment.sol
    uint80 assessmentId;
    // The identifier of the cover on which this claim is submitted
    uint32 coverId;
    // Amount requested as part of this claim up to the total cover amount
    uint96 amount;
    // The index of of the asset address stored at addressOfAsset which is expected at payout.
    uint8 payoutAsset;
    // True if the payout is already redeemed. Prevents further payouts on the claim if it is
    // accepted.
    bool payoutRedeemed;
    // True if cover NFT is already redeemed when a claim is either denied or the payout status is
    // unclaimed. Prevents further attempts to redeemd the cover NFT if the claim is denied.
    // If a malicious user sends the NFT back after a redemption, he will not be able to recover
    // the NFT and transfer all the ETH accrued from assessment deposits to the pool which would
    // result in a denial of service for users who need to redeem payouts.
    bool coverRedeemed;
  }

  /* ========== VIEWS ========== */

  function claims(uint id) external view returns (
    uint80 assessmentId,
    uint32 coverId,
    uint96 amount,
    uint8 payoutAsset,
    bool payoutRedeemed,
    bool coverRedeemed
  );

  /*
   *  Claim structure but in a human-friendly format.
   *
   *  Contains aggregated values that give an overall view about the claim and other relevant
   *  pieces of information such as cover period, asset symbol etc. This structure is not used in
   *  any storage variables.
   */
  struct ClaimDisplay {
    uint id;
    uint productId;
    uint coverId;
    uint amount;
    string assetSymbol;
    uint assetIndex;
    uint coverStart;
    uint coverEnd;
    uint start;
    uint end;
    uint claimStatus;
    uint payoutStatus;
  }

  /* ========== VIEWS ========== */

  function config() external view returns (
    uint8 payoutRedemptionPeriodDays,
    uint16 minAssessmentDepositRatio,
    uint16 maxRewardRatio,
    uint16 rewardRatio
  );

  function claimants(uint id) external view returns (address);

  function getClaimsCount() external view returns (uint);

  /* === MUTATIVE FUNCTIONS ==== */

  function submitClaim(
    uint24 coverId,
    uint96 requestedAmount,
    bool hasProof,
    string calldata ipfsProofHash
  ) external payable;

  function redeemClaimPayout(uint104 id) external;

  function redeemCoverForDeniedClaim(uint claimId) external;

  function updateUintParameters(UintParams[] calldata paramNames, uint[] calldata values) external;

  /* ========== EVENTS ========== */

  event ClaimSubmitted(address user, uint104 claimId, uint32 coverId, uint24 productId);
  event ProofSubmitted(uint indexed coverId, address indexed owner, string ipfsHash);
  event ClaimPayoutRedeemed(address indexed user, uint256 amount, uint104 claimId);

}