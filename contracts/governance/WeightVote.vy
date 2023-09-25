# @version 0.3.7
"""
@title Weight vote
@author 0xkorin, Yearn Finance
@license GNU AGPLv3
"""

interface Measure:
    def total_vote_weight() -> uint256: view
    def vote_weight(_account: address) -> uint256: view

interface Pool:
    def num_assets() -> uint256: view

genesis: public(immutable(uint256))
pool: public(immutable(address))

management: public(address)
pending_management: public(address)

measure: public(address)
num_assets: public(HashMap[uint256, uint256])
total_votes: public(HashMap[uint256, uint256]) # epoch => total votes
votes: public(HashMap[uint256, uint256[33]]) # epoch => [blank vote, ..protocol votes..]
votes_user: public(HashMap[address, HashMap[uint256, uint256[33]]]) # user => epoch => [blank vote, ..protocol votes..]
voted: public(HashMap[address, HashMap[uint256, bool]]) # user => epoch => voted?

event SetMeasure:
    measure: indexed(address)

event PendingManagement:
    management: indexed(address)

event SetManagement:
    management: indexed(address)

WEEK: constant(uint256) = 7 * 24 * 60 * 60
EPOCH_LENGTH: constant(uint256) = 4 * WEEK
VOTE_LENGTH: constant(uint256) = WEEK
VOTE_START: constant(uint256) = EPOCH_LENGTH - VOTE_LENGTH
VOTE_SCALE: constant(uint256) = 10_000

@external
def __init__(_genesis: uint256, _pool: address, _measure: address):
    assert _genesis <= block.timestamp
    assert _pool != empty(address)
    assert _measure != empty(address)

    genesis = _genesis
    pool = _pool
    self.management = msg.sender
    self.measure = _measure

    log SetManagement(msg.sender)
    log SetMeasure(_measure)

@external
@view
def epoch() -> uint256:
    return self._epoch()

@internal
@view
def _epoch() -> uint256:
    return (block.timestamp - genesis) / EPOCH_LENGTH

@external
@view
def vote_open() -> bool:
    return self._vote_open()

@internal
@view
def _vote_open() -> bool:
    return (block.timestamp - genesis) % EPOCH_LENGTH >= VOTE_START

@external
def vote(_votes: DynArray[uint256, 33]):
    epoch: uint256 = self._epoch()
    assert self._vote_open()
    assert not self.voted[msg.sender][epoch]

    n: uint256 = self.num_assets[epoch]
    if n == 0:
        n = Pool(pool).num_assets()
        assert n > 0
        self.num_assets[epoch] = n
    assert len(_votes) <= n + 1

    weight: uint256 = Measure(self.measure).vote_weight(msg.sender)
    assert weight > 0
    self.total_votes[epoch] += weight
    self.voted[msg.sender][epoch] = True

    total: uint256 = 0
    for i in range(33):
        if i == len(_votes):
            break
        if _votes[i] == 0:
            continue

        votes: uint256 = _votes[i] * weight / VOTE_SCALE
        self.votes[epoch][i] += votes
        self.votes_user[msg.sender][epoch][i] = votes
        total += _votes[i]

    assert total == VOTE_SCALE

@external
def set_measure(_measure: address):
    assert msg.sender == self.management
    assert _measure != empty(address)
    assert not self._vote_open()
    self.measure = _measure
    log SetMeasure(_measure)

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
