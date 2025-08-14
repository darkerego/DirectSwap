# DirectSwap
=================

<b>Copyright Darkerego, 2025</b>


<p>
This is a smart contract that performs swaps
by directly interacting with Uniswap V2, V3 and V4
liquidity pools. It also exposes quote helpers (`quoteV2`, `quoteV3`, `quoteV4`) for estimating swap outputs without executing trades.
</p>

<p>
The contract has external functions that 
perform v2 swaps, v3 swaps, as well as a 
function that swaps the output token back 
into the input token in the same transaction. 
This is useful for detecting malicious 
tokens. 
</p>


#### Changelog


<p>
- Aug 9 2025
  - Optimized logic
  - add external helper functions
  - expose external arbitrary call function
</p>