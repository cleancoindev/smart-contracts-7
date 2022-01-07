
/*
  struct PoolBucket {
    // slot 0
    uint64 rewardPerSecondCut;
    // amount of nxm requested for unstake
    uint96 nxmUnstakeRequested; // 100
    uint96 burntNxm; // 14
    // amount of unstaked nxm
    uint96 nxmUnstaked; // 86
  }
 */

const poolBuckets = [
  { unstakeRequested: 100 },
  { unstakeRequested: 20 },
  { unstakeRequested: 30 },
];

let stakeActive = 1000;
let stakeInactive = 500;
let stakeInactiveBurned = 0;
let totalBurnableStake = stakeActive + stakeInactive;
let inactiveStakeBurnRatio = stakeInactiveBurned / stakeInactive;

const buckets = [
  {
    unstakeRequested: 100,
    virtualUnstakeRequested: 0,
    unstaked: 0,
    burned: 0,
  },
];

function burn (amount) {
  const totalStake = stakeActive + stakeInactive;
  const burnRatio = amount / totalStake;
  stakeActive = stakeActive - stakeActive * burnRatio;
  stakeInactive = stakeInactive - stakeInactive * burnRatio;
  totalBurnableStake = stakeActive + stakeInactive;
  stakeInactiveBurned = stakeInactive * burnRatio;
  inactiveStakeBurnRatio = stakeInactiveBurned / stakeInactive;
}

function processUnstakes (maxUnstake) {

  let totalUnstakeAmount = 0;
  for (let i = 0; i < buckets.length; i++) {
    const bucket = buckets[i];

    const unstakeAmount = Math.min(maxUnstake, bucket.unstakeRequested);
    bucket.unstaked = unstakeAmount * (1 - inactiveStakeBurnRatio);
    bucket.burned = unstakeAmount - bucket.unstaked;

    maxUnstake -= unstakeAmount;
    if (maxUnstake === 0) {
      break;
    }
    totalUnstakeAmount += unstakeAmount;
  }

  stakeInactiveBurned -= totalUnstakeAmount;
  stakeInactive = stakeInactive * (1 - inactiveStakeBurnRatio);
}

function addUnstakeRequest (amount) {
  stakeActive = stakeActive - amount;
  stakeInactive = stakeInactive + amount;
  stakeInactiveBurned = inactiveStakeBurnRatio * stakeInactive / (1 - inactiveStakeBurnRatio);

  buckets.push({
    unstakeRequested: amount,
    virtualUnstakeRequested: inactiveStakeBurnRatio * amount / (1 - inactiveStakeBurnRatio),
    unstaked: 0,
    burned: 0,
  });

}

function increaseYield (percentage) {
  const totalStake = stakeActive + stakeInactive;
  const increaseRatio = percentage / 100;
  stakeActive = stakeActive + stakeActive * increaseRatio;
  totalBurnableStake = stakeActive + stakeInactive;
  inactiveStakeBurnRatio = stakeInactiveBurned / stakeInactive;
}

/*
 scripts
 */
burn(150);
processUnstakes(50);
addUnstakeRequest(100);
increaseYield(5);
burn(134.5);

console.log({
  stakeActive,
  stakeInactive,
  stakeInactiveBurned,
  totalBurnableStake,
  inactiveStakeBurnRatio,
  buckets,
});
