pragma solidity ^0.4.24;

import "openzeppelin-solidity/contracts/token/ERC20/ERC20.sol";
import "openzeppelin-solidity/contracts/math/SafeMath.sol";

contract MultiPartyEscrow {
    
    using SafeMath for uint256;
    
    //TODO: we could use uint64 for value, nonce and expiration (it could be cheaper to store but more expensive to operate with)
    //the full ID of "atomic" payment channel = "[this, channelId, nonce]"
    struct PaymentChannel {
        uint256 nonce;       // "nonce" of the channel (by changing nonce we effectivly close the old channel ([this, channelId, oldNonce])
                             //  and open the new channel [this, channelId, newNonce])
                             //!!! nonce also prevents race conditon between channelClaim and channelExtendAndAddFunds
        address sender;      // The account sending payments.
        address signer;      // signer on behalf of sender
        address recipient;   // The account receiving the payments.
        bytes32 groupId;     // id of group of replicas who share the same payment channel
                             // You should generate groupId randomly in order to prevent
                             // two PaymentChannel with the same [recipient, groupId]
        uint256 value;       // Total amount of tokens deposited to the channel. 
        uint256 expiration;  // Timeout (in block numbers) in case the recipient never closes.
                             // if block.number > expiration then sender can call channelClaimTimeout
    }


    mapping (uint256 => PaymentChannel) public channels;
    mapping (address => uint256)        public balances; //tokens which have been deposit but haven't been escrowed in the channels
   
    mapping (bytes32 => bool) public usedMessages;

    uint256 public nextChannelId; //id of the next channel (and size of channels)

    ERC20 public token; // Address of token contract


    // Events
    event ChannelOpen(uint256 channelId, uint256 nonce, address indexed sender, address signer, address indexed recipient, bytes32 indexed groupId, uint256 amount, uint256 expiration);
    event ChannelOpenByThirdParty(uint256 channelId, uint256 nonce, address thirdParty, address indexed signer, address indexed recipient, bytes32 indexed groupId, uint256 amount, uint256 expiration, uint256 fees, uint256 messageNonce);
    event ChannelClaim(uint256 indexed channelId, uint256 nonce, address indexed recipient, uint256 claimAmount, uint256 sendBackAmount, uint256 keepAmount);
    event ChannelSenderClaim(uint256 indexed channelId, uint256 nonce, uint256 claimAmount);
    event ChannelExtend(uint256 indexed channelId, uint256 newExpiration);
    event ChannelAddFunds(uint256 indexed channelId, uint256 additionalFunds);
    event DepositFunds(address indexed sender, uint256 amount);
    event WithdrawFunds(address indexed sender, uint256 amount);
    event TransferFunds(address indexed sender, address indexed receiver, uint256 amount);

    constructor (address _token)
    public
    {
        token = ERC20(_token);
    }

    function deposit(uint256 value)
    public
    returns(bool)
    {
        require(token.transferFrom(msg.sender, this, value), "Unable to transfer token to the contract");
        balances[msg.sender] = balances[msg.sender].add(value);
        emit DepositFunds(msg.sender, value);
        return true;
    }

    function deposit(address sender, uint256 value)
    public
    returns(bool)
    {
        require(token.transferFrom(sender, this, value), "[depositByThirdParty] Unable to transfer token to the contract");
        balances[sender] = balances[sender].add(value);
        emit DepositFunds(sender, value);
        return true;
    }

    function withdraw(uint256 value)
    public
    returns(bool)
    {
        require(balances[msg.sender] >= value);
        require(token.transfer(msg.sender, value));
        balances[msg.sender] = balances[msg.sender].sub(value);
        emit WithdrawFunds(msg.sender, value);
        return true;
    }

    function transfer(address receiver, uint256 value)
    public
    returns(bool)
    {
        require(balances[msg.sender] >= value);
        balances[msg.sender] = balances[msg.sender].sub(value);
        balances[receiver] = balances[receiver].add(value);

        emit TransferFunds(msg.sender, receiver, value);
        return true;
    }


    //open a channel, token should be already being deposit
    //openChannel should be run only once for given sender, recipient, groupId
    //channel can be reused even after channelClaim(..., isSendback=true)
    function openChannel(address signer, address recipient, bytes32 groupId, uint256 value, uint256 expiration)
    public
    returns(bool)
    {
        require(balances[msg.sender] >= value);
        require(signer != address(0));

        channels[nextChannelId] = PaymentChannel({
            nonce        : 0,
            sender       : msg.sender,
            signer       : signer,
            recipient    : recipient,
            groupId      : groupId,
            value        : value,
            expiration   : expiration
        });

        balances[msg.sender] = balances[msg.sender].sub(value);
        emit ChannelOpen(nextChannelId, 0, msg.sender, signer, recipient, groupId, value, expiration);
        nextChannelId += 1;
        return true;
    }

    function openChannelByThirdParty(address signer, address recipient, bytes32 groupId, uint256 value, uint256 expiration, uint256 fee, uint256 messageNonce, bytes memory signature)
    public
    returns(bool)
    {
        require(balances[signer] >= value + fee, "Insufficient funds at Signer MPE wallet.");
        require(signer != address(0), "Signer is the Contract's Owner.");

        // compose the message which was signed
        bytes32 message = prefixed(keccak256(abi.encodePacked(this, msg.sender, signer, recipient, groupId, value, expiration, fee, messageNonce)));

        require(checkSignature(signer, message, signature), "Invalid Signature.");

        // check for replay attack (message can be used only once)
        require(!usedMessages[message], "[OpenChannel] Message already used.");

        channels[nextChannelId] = PaymentChannel({
            nonce        : 0,
            sender       : signer,
            signer       : signer,
            recipient    : recipient,
            groupId      : groupId,
            value        : value,
            expiration   : expiration
        });

        // Transferring Fee to ThirdParty
        balances[signer] = balances[signer].sub(fee);
        balances[msg.sender] = balances[msg.sender].add(fee);

        // Transferring to Channel
        balances[signer] = balances[signer].sub(value);

        emit ChannelOpenByThirdParty(nextChannelId, 0, msg.sender, signer, recipient, groupId, value, expiration, fee, messageNonce);

        nextChannelId += 1;
        usedMessages[message] = true;
        return true;
    }

    function checkSignature(address signer, bytes32 message, bytes memory signature)
    public
    pure
    returns (bool)
    {
        bytes32 r;
        bytes32 s;
        uint8 v;
        assembly {
            r := mload(add(signature, 0x20))
            s := mload(add(signature, 0x40))
            v := byte(0, mload(add(signature, 0x60)))
        }
        if (v < 27) v += 27;

        return ecrecover(message, v, r, s) == signer;
    }

    function depositAndOpenChannel(address signer, address recipient, bytes32 groupId, uint256 value, uint256 expiration)
    public
    returns(bool)
    {
        require(deposit(value));
        require(openChannel(signer, recipient, groupId, value, expiration));
        return true;
    }


    function _channelSendbackAndReopenSuspended(uint256 channelId)
    private
    {
        PaymentChannel storage channel = channels[channelId];

        balances[channel.sender] = balances[channel.sender].add(channel.value);
        channel.value            = 0;
        channel.nonce           += 1;
        channel.expiration       = 0;
    }

    /**
     * @dev function to claim multiple channels at a time. Needs to send limited channels per call
     * @param channelIds list of channel Ids
     * @param amounts list of amounts should be aligned with channel ids index
     * @param isSendbacks list of sendbacks flags
     * @param v channel senders signatures in V R S for each channel
     * @param r channel senders signatures in V R S for each channel
     * @param s channel senders signatures in V R S for each channel
     */
    function multiChannelClaim(uint256[] channelIds, uint256[] amounts, bool[] isSendbacks, uint8[] v, bytes32[] r, bytes32[] s)
    public
    {
        uint256 len = channelIds.length;

        require(amounts.length == len && isSendbacks.length == len && v.length == len && r.length == len && s.length == len);
        for(uint256 i=0; i<len ; i++) {
            channelClaim(channelIds[i], amounts[i], v[i], r[i], s[i], isSendbacks[i]);
        }

    }

    function channelClaim(uint256 channelId, uint256 amount, uint8 v, bytes32 r, bytes32 s, bool isSendback)
    public
    {
        PaymentChannel storage channel = channels[channelId];
        require(amount <= channel.value);
        require(msg.sender == channel.recipient);

        //compose the message which was signed
        bytes32 message = prefixed(keccak256(abi.encodePacked(this, channelId, channel.nonce, amount)));
        // check that the signature is from the signer
        address signAddress = ecrecover(message, v, r, s);
        require(signAddress == channel.signer);

        //transfer amount from the channel to the sender
        channel.value        =        channel.value.sub(amount);
        balances[msg.sender] = balances[msg.sender].add(amount);

        if (isSendback)
            {
                _channelSendbackAndReopenSuspended(channelId);
                emit ChannelClaim(channelId, channel.nonce, msg.sender, amount, channel.value, 0);
            }
            else
            {
                //reopen new "channel", without sending back funds to "sender"
                channel.nonce += 1;
                emit ChannelClaim(channelId, channel.nonce, msg.sender, amount, 0, channel.value);
            }
    }



    /// the sender can extend the expiration at any time
    function channelExtend(uint256 channelId, uint256 newExpiration)
    public
    returns(bool)
    {
        PaymentChannel storage channel = channels[channelId];

        require(msg.sender == channel.sender);
        require(newExpiration >= channel.expiration);

        channels[channelId].expiration = newExpiration;

        emit ChannelExtend(channelId, newExpiration);
        return true;
    }

    /// the sender could add funds to the channel at any time
    /// any one can fund the channel irrespective of the sender
    function channelAddFunds(uint256 channelId, uint256 amount)
    public
    returns(bool)
    {
        require(balances[msg.sender] >= amount);

        //tranfser amount from sender to the channel
        balances[msg.sender]      = balances[msg.sender].sub     (amount);
        channels[channelId].value = channels[channelId].value.add(amount);

        emit ChannelAddFunds(channelId, amount);
        return true;
    }

    function channelExtendAndAddFunds(uint256 channelId, uint256 newExpiration, uint256 amount)
    public
    {
        require(channelExtend(channelId, newExpiration));
        require(channelAddFunds(channelId, amount));
    }

    // sender can claim refund if the timeout is reached
    function channelClaimTimeout(uint256 channelId)
    public
    {
        require(msg.sender == channels[channelId].sender);
        require(block.number >= channels[channelId].expiration);
        _channelSendbackAndReopenSuspended(channelId);

        emit ChannelSenderClaim(channelId, channels[channelId].nonce, channels[channelId].value);
    }

    /// builds a prefixed hash to mimic the behavior of ethSign.
    function prefixed(bytes32 hash) internal pure returns (bytes32)
    {
        return keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", hash));
    }

    // Paying Gas for user
    function depositByThirdParty(address signer, uint256 value, uint256 fee, uint256 messageNonce, bytes memory signature)
    public
    {
        require(token.balanceOf(signer) >= value + fee, "Insufficient funds at Signer wallet.");
        bytes32 message = prefixed(keccak256(abi.encodePacked(this, msg.sender, signer, value, fee, messageNonce)));
        require(checkSignature(signer, message, signature), "Invalid Signature.");

        require(signer != address(0));

        // check for replay attack (message can be used only once)
        require(!usedMessages[message], "[depositByThirdParty] Message already used.");

        // Execute the original approve function
        // token._allowed[signer][this] = value;
        // emit token.Approval(signer, this, value);

        require(token.approve(signer, value + fee), "[depositByThirdParty] Not Approved.");
        deposit(signer, value + fee);

        require(balances[signer] >= value + fee, "Insufficient funds at Signer MPE wallet.");
        // Transferring Fee to ThirdParty
        balances[signer] = balances[signer].sub(fee);
        balances[msg.sender] = balances[msg.sender].add(fee);

        usedMessages[message] = true;
    }
}