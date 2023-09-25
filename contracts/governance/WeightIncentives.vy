# @version 0.3.7
"""
@title Incentives for weight vote
@author 0xkorin, Yearn Finance
@license GNU AGPLv3
"""

from vyper.interfaces import ERC20

interface Pool:
    def num_assets() -> uint256: view

interface Voting:
    def genesis() -> uint256: view
    def votes(_epoch: uint256, _idx: uint256) -> uint256: view
    def votes_user(_account: address, _epoch: uint256, _idx: uint256) -> uint256: view

genesis: public(immutable(uint256))
pool: public(immutable(Pool))
voting: public(immutable(Voting))
management: public(address)
pending_management: public(address)
treasury: public(address)
incentives: public(HashMap[uint256, HashMap[uint256, HashMap[address, uint256]]]) # epoch => idx => incentive token => incentive amount
unclaimed: public(HashMap[uint256, HashMap[address, uint256]]) # epoch => incentive token => incentive amount
user_claimed: public(HashMap[address, HashMap[uint256, HashMap[uint256, HashMap[address, bool]]]]) # account => epoch => idx => incentive token => claimed?
deposit_deadline: public(uint256)
claim_deadline: public(uint256)

event PendingManagement:
    management: indexed(address)

event SetManagement:
    management: indexed(address)

WEEK: constant(uint256) = 7 * 24 * 60 * 60
EPOCH_LENGTH: constant(uint256) = 4 * WEEK
VOTE_LENGTH: constant(uint256) = WEEK
VOTE_START: constant(uint256) = EPOCH_LENGTH - VOTE_LENGTH

@external
def __init__(_pool: address, _voting: address):
    voting = Voting(_voting)
    genesis = voting.genesis()
    pool = Pool(_pool)
    self.management = msg.sender
    self.treasury = msg.sender
    self.deposit_deadline = EPOCH_LENGTH
    self.claim_deadline = 1

@external
@view
def epoch() -> uint256:
    return self._epoch()

@internal
@view
def _epoch() -> uint256:
    return (block.timestamp - genesis) / EPOCH_LENGTH

@external
def deposit(_idx: uint256, _token: address, _amount: uint256):
    assert (block.timestamp - genesis) % EPOCH_LENGTH <= self.deposit_deadline
    assert pool.num_assets() >= _idx
    epoch: uint256 = self._epoch()
    self.incentives[epoch][_idx][_token] += _amount
    self.unclaimed[epoch][_token] += _amount

    assert ERC20(_token).transferFrom(msg.sender, self, _amount, default_return_value=True)

@external
@view
def claimable(_epoch: uint256, _idx: uint256, _token: address, _account: address) -> uint256:
    if self._epoch() <= _epoch or self.user_claimed[_account][_epoch][_idx][_token]:
        return 0
    
    total_votes: uint256 = voting.votes(_epoch, _idx)
    if total_votes == 0:
        return 0
    votes: uint256 = voting.votes_user(_account, _epoch, _idx)
    return self.incentives[_epoch][_idx][_token] * votes / total_votes

@external
def claim_many(_epochs: DynArray[uint256, 16], _idx: DynArray[uint256, 16], _tokens: DynArray[address, 16], _account: address = msg.sender):
    assert len(_epochs) == len(_idx)
    assert len(_epochs) == len(_tokens)
    for i in range(16):
        if i == len(_epochs):
            break
        self._claim(_epochs[i], _idx[i], _tokens[i], _account)

@external
def claim(_epoch: uint256, _idx: uint256, _token: address, _account: address = msg.sender):
    self._claim(_epoch, _idx, _token, _account)

@internal
def _claim(_epoch: uint256, _idx: uint256, _token: address, _account: address):
    assert self._epoch() > _epoch
    total_votes: uint256 = voting.votes(_epoch, _idx)
    if total_votes == 0:
        return
    votes: uint256 = voting.votes_user(_account, _epoch, _idx)
    amount: uint256 = self.incentives[_epoch][_idx][_token] * votes / total_votes
    if self.user_claimed[_account][_epoch][_idx][_token] or amount == 0:
        return
    self.user_claimed[_account][_epoch][_idx][_token] = True
    self.unclaimed[_epoch][_token] -= amount

    assert ERC20(_token).transfer(_account, amount, default_return_value=True)

@external
@view
def sweepable(_epoch: uint256, _token: address) -> uint256:
    if self._epoch() <= _epoch + self.claim_deadline:
        return 0
    return self.unclaimed[_epoch][_token]

@external
def sweep(_epoch: uint256, _token: address, _recipient: address = msg.sender):
    assert msg.sender == self.treasury
    assert self._epoch() > _epoch + self.claim_deadline

    amount: uint256 = self.unclaimed[_epoch][_token]
    assert amount > 0
    self.unclaimed[_epoch][_token] = 0

    assert ERC20(_token).transfer(_recipient, amount, default_return_value=True)

@external
def set_treasury(_treasury: address):
    assert msg.sender == self.management or msg.sender == self.treasury
    assert _treasury != empty(address)
    self.treasury = _treasury

@external
def set_deposit_deadline(_deadline: uint256):
    assert msg.sender == self.management
    assert _deadline <= EPOCH_LENGTH
    self.deposit_deadline = _deadline

@external
def set_claim_deadline(_deadline: uint256):
    assert msg.sender == self.management
    assert _deadline >= 1
    self.claim_deadline = _deadline

@external
def set_management(_management: address):
    """
    @notice 
        Set the pending management address.
        Needs to be accepted by that account separately to transfer management over
    @param _management New pending management address
    """
    assert msg.sender == self.management
    self.pending_management = _management
    log PendingManagement(_management)

@external
def accept_management():
    """
    @notice 
        Accept management role.
        Can only be called by account previously marked as pending management by current management
    """
    assert msg.sender == self.pending_management
    self.pending_management = empty(address)
    self.management = msg.sender
    log SetManagement(msg.sender)
