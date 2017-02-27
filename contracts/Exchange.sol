pragma solidity ^0.4.2;
import "Token.sol";
import "SafeMath.sol";

contract Exchange is SafeMath {

  address PROTOCOL_TOKEN;

  mapping (bytes32 => uint256) public fills;

  //need to rethink which params get indexed
  //should p2p fills log different events?
  event LogFillByUser(
    address indexed maker,
    address indexed taker,
    address tokenM,
    address tokenT,
    uint256 valueM,
    uint256 valueT,
    uint256 expiration,
    bytes32 orderHash,
    address indexed feeRecipient,
    uint256 feeM,
    uint256 feeT,
    uint256 fillValue,
    uint256 remainingValue
  );

  event LogFillByToken(
    address maker,
    address taker,
    address indexed tokenM,
    address indexed tokenT,
    uint256 valueM,
    uint256 valueT,
    uint256 expiration,
    bytes32 indexed orderHash,
    address feeRecipient,
    uint256 feeM,
    uint256 feeT,
    uint256 fillValue,
    uint256 remainingValue
  );

  event LogCancel(
    address indexed maker,
    address indexed tokenM,
    address indexed tokenT,
    uint256 valueM,
    uint256 valueT,
    uint256 expiration,
    bytes32 orderHash,
    uint256 cancelValue,
    uint256 remainingValue
  );

  //tokens = [tokenM, tokenT]
  //values = [valueM, valueT]
  //fees = [feeM, feeT]
  //rs = [r, s]
  function fill(address maker, address feeRecipient, address[2] tokens, uint256[2] values,  uint256[2] fees, uint256 expiration, uint256 fillValue, uint8 v, bytes32[2] rs) returns (bool success) {
   assert(block.timestamp < expiration);
   assert(fillValue > 0);

   bytes32 orderHash = sha3(
     this,
     maker,
     tokens[0],
     tokens[1],
     values[0],
     values[1],
     expiration
   );

   assert(safeAdd(fills[orderHash], fillValue) <= values[0]);
   assert(validSignature(maker, sha3(
     orderHash,
     feeRecipient,
     fees[0],
     fees[1]
   ), v, rs[0], rs[1]));

   assert(Token(tokens[0]).transferFrom(maker, msg.sender, fillValue));
   assert(Token(tokens[1]).transferFrom(msg.sender, maker, partialFill(values, fillValue)));
   fills[orderHash] = safeAdd(fills[orderHash], fillValue);

   if (feeRecipient != address(0)) {
     if (fees[0] > 0) {
       assert(Token(PROTOCOL_TOKEN).transferFrom(maker, feeRecipient, partialFill(values, fees[0])));
     }
     if (fees[1] > 0) {
       assert(Token(PROTOCOL_TOKEN).transferFrom(msg.sender, feeRecipient, partialFill(values, fees[1])));
     }
   }

   // log events
   LogFillEvents([maker, msg.sender, tokens[0], tokens[1], feeRecipient],
             [values[0], values[1], expiration, fees[0], fees[1], fillValue, values[0] - fills[orderHash]],
             orderHash
   );

   return true;
 }

  //addresses = [maker, taker, tokenM, tokenT, feeRecipient]
  //values = [valueM, valueT, expiration, feeM, feeT, fillValue, remainingValue]
  function LogFillEvents(address[5] addresses, uint256[7] values, bytes32 orderHash) {
    LogClaimByUser(addresses[0], addresses[1], addresses[2], addresses[3], values[0], values[1], values[2], orderHash, addresses[4], values[3], values[4], values[5], values[6]);
    LogClaimByToken(addresses[0], addresses[1], addresses[2], addresses[3], values[0], values[1], values[2], orderHash, addresses[4], values[3], values[4], values[5], values[6]);
  }

  //tokens = [tokenM, tokenT]
  //values = [valueM, valueT]
  //rs = [r, s]
  function fillOTC(address maker, address taker, address[2] tokens, uint256[2] values, uint256 expiration, uint256 fillValue, uint8 v, bytes32[2] rs) returns (bool success) {
    assert(msg.sender == taker);
    assert(fillValue > 0);

    bytes32 orderHash = sha3(
      this,
      maker,
      taker,
      tokens[0],
      tokens[1],
      values[0],
      values[1],
      expiration
    );

    assert(safeAdd(fills[orderHash], fillValue) <= values[0]);
    assert(validSignature(maker, orderHash, v, rs[0], rs[1]));

    assert(Token(tokens[0]).transferFrom(maker, msg.sender, fillValue));
    assert(Token(tokens[1]).transferFrom(msg.sender, maker, partialFill(values, fillValue)));
    fills[orderHash] = safeAdd(fills[orderHash], fillValue);

    //log events
    LogFillEvents([maker, msg.sender, tokens[0], tokens[1], address(0)],
              [values[0], values[1], expiration, 0, 0, fillValue, values[0] - fills[orderHash]],
              orderHash
    );

    return true;
  }

  function fillAll(address[] makers, address[] feeRecipients, address[2][] tokens, uint256[2][] values, uint256[2][] fees, uint256[] expirations, uint256[] fillValues, uint8[] v, bytes32[2][] rs) returns (bool success) {
    for (uint8 i = 0; i < makers.length; i++) {
      assert(fill(makers[i], feeRecipients[i], tokens[i], values[i], fees[i], expirations[i], fillValues[i], v[i], rs[i]));
    }

    return true;
  }

  function cancel(address maker, address[2] tokens, uint256[2] values, uint256 expiration, uint256 cancelValue) returns (bool success) {
    assert(msg.sender == maker);
    assert(cancelValue > 0);

    bytes32 orderHash = sha3(
      this,
      maker,
      tokens[0],
      tokens[1],
      values[0],
      values[1],
      expiration
    );

    fills[orderHash] = safeAdd(fills[orderHash], cancelValue);

    // log events
    LogCancel(maker, tokens[0], tokens[1], values[0], values[1], expiration, orderHash, cancelValue, values[0] - fills[orderHash]);
    return true;
  }

  // values = [ valueM, valueT ]
  function partialFill(uint256[2] values, uint256 fillValue) constant internal returns (uint256) {
    if (fillValue > values[0] || fillValue == 0) {
      throw;
    }
    // throw if rounding error > 0.01%
    if (values[1] < 10**4 && values[1] * fillValue % values[0] != 0) {
      throw;
    }
    return safeMul(fillValue, values[1]) / values[0];
  }

  function validSignature(address maker, bytes32 msgHash, uint8 v, bytes32 r, bytes32 s) constant returns (bool success) {
    return maker == ecrecover(sha3('\x19Ethereum Signed Message:\n32', msgHash), v, r, s);
  }

  function assert(bool assertion) internal {
    if (!assertion) throw;
  }

}