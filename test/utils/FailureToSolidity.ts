import FailureRaw from '../../cache/invariant/failures/DopplerInvariantsTest/invariant_CantSellMoreThanNumTokensToSell.json';

// const failureJson = JSON.parse(FailureRaw);

console.log(FailureRaw['call_sequence'].length);


FailureRaw['call_sequence'].forEach((call: any) => {
  const func = call['func_name'];

  if (func === 'goNextEpoch') {
    console.log('goNextEpoch();');
  } else if (func === 'buyExactAmountIn') {
    console.log(`buy(-${call['raw_args']});`);
  } else if (func === 'sellExactIn') {
    console.log(`sell(-${call['raw_args']});`);
  }
});
