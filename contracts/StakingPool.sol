// SPDX-License-Identifier: GPL-3.0-only

pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract StakingPool is ERC20 {

  struct PoolBucket {
    // slot 0
    uint64 rewardPerSecondCut;
    uint96 stakedWhenProcessed;  // what's this for?
    // amount of shares requested for unstake
    uint96 unstakeRequested;
    // slot 1
    // underlying amount unstaked, stored for rate calculation
    uint96 unstakedNXM;
    // amount of unstaked shares
    uint96 unstaked;
    // uint64 _unused;
    // slot 3
    uint96 totalCapacityExpiring;
  }

  struct ProductBucket {
    uint96 coverAmountExpiring;
    // expiring capacity for the last 5 buckets
    // but only if this is the checkpoint bucket
    uint96 checkpointCapacityExpiring;
    // uint64 _unused;
  }

  struct Product {
    uint96 activeCoverAmount;
    uint16 weight;
    uint16 lastBucket;
    // uint128 _unused;
    mapping(uint => ProductBucket) buckets;
  }

  struct UnstakeRequest {
    uint96 amount;
    uint96 withdrawn;
    uint16 poolBucketIndex;
    // uint48 _unused;
  }

  struct Staker {
    uint96 pendingUnstakeAmount;
    // unstakeRequests mapping keys. zero means no unstake exists.
    uint32 firstUnstakeId;
    uint32 lastUnstakeId;
    uint16 lastUnstakeBucketIndex;
    // uint48 _unused;
  }

  /* slot 0 */
  // bucket index => pool bucket
  mapping(uint => PoolBucket) public poolBuckets;

  /* slot 1 */
  // staker address => staker unstake info
  // todo: unstakes make take a looooong time, consider issuing an nft that represents staker's requests
  mapping(address => Staker) public stakers;

  /* slot 2 */
  mapping(address => mapping(uint32 => UnstakeRequest)) unstakeRequests;

  /* slot 3 */
  // product id => product info
  mapping(uint => Product) public products;

  /* slot 4 */
  // array with product ids to be able to iterate them
  // todo: pack me
  uint[] public poolProductsIds;

  /* slot 5 */
  uint96 public currentStake;
  uint64 public currentRewardPerSecond;
  uint32 public lastRewardTime;
  uint16 public lastPoolBucketIndex;
  uint16 public lastUnstakeBucketIndex;
  uint16 public currentMaxProductWeight;
  uint16 public maxTotalWeight; // max leverage

  /* slot 6 */
  uint96 public totalUnstakeRequested;
  uint96 public totalActiveCoverAmount;

  /* immutables */
  ERC20 public immutable nxm;
  address public immutable coverContract;

  /* constants */
  uint public constant TOKEN_PRECISION = 1e18;
  uint public constant PARAM_PRECISION = 10_000;
  uint public constant BUCKET_SIZE = 7 days;

  modifier onlyCoverContract {
    require(msg.sender == coverContract, "StakingPool: Caller is not the cover contract");
    _;
  }

  constructor (address _nxm) ERC20("Staked NXM", "SNXM") {
    nxm = ERC20(_nxm);
    coverContract = msg.sender;
  }

  function initialize() external onlyCoverContract {
    require(lastPoolBucketIndex == 0, "Staking Pool: Already initialized");
    lastPoolBucketIndex = uint16(block.timestamp / BUCKET_SIZE);
    lastUnstakeBucketIndex = uint16(block.timestamp / BUCKET_SIZE);
  }

  /* View functions */

  /* State-changing functions */

  function processPoolBuckets() internal returns (uint staked) {

    uint rewardPerSecond;
    uint rewardTime;
    uint poolBucketIndex;

    // all vars are in the same slot, uses 1 SLOAD
    staked = currentStake;
    rewardPerSecond = currentRewardPerSecond;
    rewardTime = lastRewardTime;
    poolBucketIndex = lastPoolBucketIndex;

    // get bucket for current time
    uint currentBucketIndex = block.timestamp / BUCKET_SIZE;

    // 1 SLOAD per loop
    while (poolBucketIndex < currentBucketIndex) {

      ++poolBucketIndex;
      uint bucketStartTime = poolBucketIndex * BUCKET_SIZE;
      staked += (bucketStartTime - rewardTime) * rewardPerSecond;

      rewardTime = bucketStartTime;
      rewardPerSecond -= poolBuckets[poolBucketIndex].rewardPerSecondCut;
      poolBuckets[poolBucketIndex].stakedWhenProcessed = uint96(staked);
    }

    // TODO: process unstakes (here?)

    staked += (block.timestamp - rewardTime) * rewardPerSecond;

    // same slot - a single SSTORE
    currentStake = uint96(staked);
    currentRewardPerSecond = uint64(rewardPerSecond);
    lastRewardTime = uint32(rewardTime);
    lastPoolBucketIndex = uint16(poolBucketIndex);
  }

  /* callable by cover contract */

  function buyCover(
    uint productId,
    uint coverAmount,
    uint rewardAmount,
    uint period,
    uint capacityFactor
  ) external {

    uint staked = processPoolBuckets();
    uint currentBucket = block.timestamp / BUCKET_SIZE;

    Product storage product = products[productId];
    uint weight = product.weight;
    uint activeCoverAmount = product.activeCoverAmount;
    uint lastBucket = product.lastBucket;

    // process expirations
    while (lastBucket < currentBucket) {
      ++lastBucket;
      activeCoverAmount -= product.buckets[lastBucket].coverAmountExpiring;
    }

    {
      // capacity checks
      uint maxActiveCoverAmount = staked * capacityFactor * weight / PARAM_PRECISION / PARAM_PRECISION;
      require(activeCoverAmount + coverAmount <= maxActiveCoverAmount, "StakingPool: No available capacity");
    }

    {
      // calculate expiration bucket, reward period, reward amount
      uint expirationBucket = (block.timestamp + period) / BUCKET_SIZE + 1;
      uint rewardPeriod = expirationBucket * BUCKET_SIZE - block.timestamp;
      uint addedRewardPerSecond = rewardAmount / rewardPeriod;

      // update state
      // 1 SLOAD + 3 SSTORE
      currentRewardPerSecond = uint64(currentRewardPerSecond + addedRewardPerSecond);
      poolBuckets[expirationBucket].rewardPerSecondCut += uint64(addedRewardPerSecond);
      product.buckets[expirationBucket].coverAmountExpiring += uint96(coverAmount);

      product.lastBucket = uint16(lastBucket);
      product.activeCoverAmount = uint96(activeCoverAmount + coverAmount);
    }
  }

  function burn() external {

    //

  }

  /* callable by stakers */

  function deposit(uint amount) external {

    uint staked = processPoolBuckets();
    uint supply = totalSupply();
    uint mintAmount = supply == 0 ? amount : (amount * supply / staked);

    // TODO: use operator transfer and transfer to TC
    nxm.transferFrom(msg.sender, address(this), amount);
    _mint(msg.sender, mintAmount);
  }

  function requestUnstake(uint96 amount) external {

    Staker memory staker = stakers[msg.sender];
    uint16 unstakeBucketIndex = uint16(block.timestamp / BUCKET_SIZE + 2);

    // update staker if we're not reusing the unstake request
    if (staker.lastUnstakeBucketIndex != unstakeBucketIndex) {

      staker.lastUnstakeId += 1;
      staker.lastUnstakeBucketIndex = unstakeBucketIndex;
      staker.pendingUnstakeAmount += amount;

      if (staker.firstUnstakeId == 0) {
        staker.firstUnstakeId = staker.lastUnstakeId;
      }

      // update staker info
      stakers[msg.sender] = staker;
    }

    // upsert unstake request
    UnstakeRequest storage unstakeRequest = unstakeRequests[msg.sender][staker.lastUnstakeId];
    unstakeRequest.amount += amount;
    unstakeRequest.poolBucketIndex = unstakeBucketIndex;

    // update pool bucket
    poolBuckets[unstakeBucketIndex].unstakeRequested += amount;

    // update totalUnstakeRequested
    totalUnstakeRequested += amount;

    _transfer(msg.sender, address(this), amount);
  }

  function withdraw() external {

    // uint lastUnstakeBucket = lastUnstakeBucketIndex;

  }

  /* callable by pool owner */

  function addProduct() external {

    //

  }

  function removeProduct() external {

    //

  }

  function setWeights() external {

    //

  }

}
