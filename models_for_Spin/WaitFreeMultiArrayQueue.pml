/***********************************************************
 * MIT License
 * Copyright (c) 2026 Vít Procházka
 *
 * Promela model of the WaitFreeMultiArrayQueue for Spin.
 *
 * An exhaustive verification with more than 2 concurrent operations
 * reaches feasibility limits and requires bitstate hashing (-DBITSTATE).
 *
 * Keep in mind that all possible temporal interleaves
 * of all participating threads will be tested
 * (this is where the BlockingMultiArrayQueue is simpler
 * because there the threads cannot interleave "inside").
 *
 * Control the number of concurrent processes by editing
 * THREAD_0/1/2_OPS_COUNT and thread_0/1/2_ops
 * and WRITERS and READERS below.
 *
 * Recommend to always set a memory limit, e.g.
 *
 *    spin -a WaitFreeMultiArrayQueue.pml
 *    cc -O2 -DMEMLIM=512 -o pan pan.c
 *    ./pan
 *
 * A random simulation with Spin, on the contrary,
 * can have a much higher number of concurrent processes:
 *
 *    spin WaitFreeMultiArrayQueue.pml
 *
 * The Queue is tested in empty state with FIRST_ARRAY_SIZE == 1
 * which is where the structure is "most dense".
 *
 * However, an optional pre-fill scenario can be specified.
 *
 * TLWACCH = Time Lag When Anything Concurrent Can Happen
 ***********************************************************/

/*********************************************
 verification data
 *********************************************/

// Hint: For construction of the pre-fill scenario it is helpful to use the Interactive Simulator:
// https://MultiArrayQueue.github.io/Simulator_WaitFreeMultiArrayQueue.html

// Idea: Run a series of verifications (switch (ideally automatically) PREFILL_STEPS from 0 upwards)
// to test starts from different positions in different fill levels (with FIRST_ARRAY_SIZE 1, CNT_ALLOWED_EXTENSIONS 2).

#define PREFILL_STEPS 0

hidden byte prefill[40] = { 1, 0, 1, 0, 1, 0, 1,
                            1, 0, 1, 0, 1, 0, 1, 0, 1, 0, 1, 0, 1, 0, 1,
                            1, 1, 1, 1,
                            0, 1, 0, 1, 0, 1, 0, 1, 0, 1, 0, 1, 0, 1 }

#define THREAD_0_OPS_COUNT 1

hidden byte thread_0_ops[2] = { 1, 0 }

#define THREAD_1_OPS_COUNT 0

hidden byte thread_1_ops[2] = { 1, 0 }

#define THREAD_2_OPS_COUNT 1

hidden byte thread_2_ops[2] = { 0, 1 }

// for asserts (count the Enqueue/Dequeue operations in thread_0/1/2_ops)
#define ENQUEUES 1
#define DEQUEUES 1

hidden short linearizationOrder[PREFILL_STEPS + ENQUEUES];  // for validation of FIFO order

hidden short prefillCntEnqueued;
hidden short prefillCntEnqueueFull;

hidden short prefillCntDequeued;
hidden short prefillCntDequeueEmpty;

short cntEnqueued = 0;
short cntEnqueueFull = 0;

short cntDequeued = 0;
short cntDequeueEmpty = 0;

/*********************************************
 private data of the WaitFreeMultiArrayQueue
 *********************************************/

#define FIRST_ARRAY_SIZE 1
#define CNT_ALLOWED_EXTENSIONS 2

// MAX_ARRAY_SIZE = FIRST_ARRAY_SIZE * (2 ^ CNT_ALLOWED_EXTENSIONS)
#define MAX_ARRAY_SIZE 4

// MAXIMUM_CAPACITY = SUM( SIZES OF ALL ARRAYS )
#define MAXIMUM_CAPACITY (1+2+4)

// NUM_THRDS = number of threads (in real code up to 64 threads are possible (results from 6 bits of lowTid))
#define NUM_THRDS 3

short nextPhase = 0;  // the (atomic) variable from which the phase numbers are drawn

// one element in the state array
// 4 bits + 60 bit phase + 64 bit value = 128 bit (to be CASed with CMPXCHG16B)
typedef OpDesc {
    short value = 0;  // the actual payload (this model assigns the same value as phase to it)
    short phase = 0;
    bool  enqueue = false;
    bool  fullOrEmpty = false;
    bool  pending = false;
    bool  inProgress = false;  // to throw an exception when multiple threads enter under one tid
}

// the state array itself
OpDesc state[NUM_THRDS];

// one ring array element: consists of two 16-byte parts (low and high)
typedef element {
    // high 128 bits
    // 6 bit divertToRix + 1 bit + 57 bit round + 64 bit value = 128 bit (to be CASed with CMPXCHG16B)
    short highValue = 0;  // the actual payload
    short highRound = 0;  // to prevent the ABA problem
    bool  highDirty = false;  // to skip the "round minus one" test in freshly allocated (clean) elements
    byte  highDivertToRix = 0;  // to which ring to divert after this element (0 == do not divert)
    // low 128 bits
    // 6 bit tid + 1 bit + 57 bit round + 1 bit unused + 3 bits + 60 bit phase = 128 bit (to be CASed with CMPXCHG16B)
    short lowPhase = 0;  // the phase number
    bool  lowEnqueue = false;  // Enqueue or Dequeue
    bool  lowFullEmpty = false;  // last result == full/empty
    bool  lowFullEmptyFinished = false;  // last result == full/empty has been helped to finish
    short lowRound = 0;  // to prevent the ABA problem
    bool  lowDirty = false;  // to skip the "round minus one" test in freshly allocated (clean) elements
    byte  lowTid = 0;  // thread index (index into the state array)
}

// one ring array
typedef array {
    element elements[MAX_ARRAY_SIZE];  // in Promela only uniform lengths, so under-utilized except of the last array
}

// the rings array
array rings[1 + CNT_ALLOWED_EXTENSIONS];

// this models the allocation of the rings array (in Promela arrays can only be statically allocated)
short ringsAllocMemory[1 + CNT_ALLOWED_EXTENSIONS] = 0;

// one element of the diversions array
// 6 bits rix + 58 bits ix = 64 bit
typedef diversion {
    short ix = 0;
    byte rix = 0;
}

// the diversions array used for the returns (by one shorter because the return from the end of rings[0] to rings[0][0] is implicit)
diversion diversions[CNT_ALLOWED_EXTENSIONS];

// writerPosition points to the next element to be enqueued (stationary state) or the element just enqueued (transient state)
// 6 bit rix + 58 bits ix + 7 bits unused + 57 bit round = 128 bit (to be CASed with CMPXCHG16B)
short writerPositionRound = 0;
byte  writerPositionRix = 0;
short writerPositionIx = 0;

// readerPosition points to the next element to be dequeued (stationary state) or the element just dequeued (transient state)
// 6 bit rix + 58 bits ix + 7 bits unused + 57 bit round = 128 bit (to be CASed with CMPXCHG16B)
short readerPositionRound = 0;
byte  readerPositionRix = 0;
short readerPositionIx = 0;

/*********************************************
 one thread (TID) that executes its defined operations
 *********************************************/
proctype thread(byte ownTid; bool onlyOneSingleEnqueue; bool onlyOneSingleDequeue)
{
    short threadOpsCount;  // for the looping over the defined thread operations
    short threadOpsIndex = 0;

    bool  ownEnqueue;  // true: own operation is Enqueue, false: Dequeue
    short ownPhase;  // the phase of own operation

    byte  helpLinearizeTid;  // TID of the linearization helpee (the help loop variable)

    short stateValue;  // values from the state array for helpLinearizeTid or elementLowTid
    short statePhase;
    bool  stateEnqueue;
    bool  stateFullOrEmpty;
    bool  statePending;
    bool  stateInProgress;

    short origEffectiveRound;  // writer position original for Enqueue / reader position original for Dequeue
    byte  origEffectiveRix;
    short origEffectiveIx;
    short effectiveRound;  // writer position prospective for Enqueue / reader position prospective for Dequeue
    byte  effectiveRix;
    short effectiveIx;
    short oppositeRound;  // reader position for Enqueue / writer position for Dequeue
    byte  oppositeRix;
    short oppositeIx;

    short elementHighValue;  // element (high part) at the effective position
    short elementHighRound;
    bool  elementHighDirty;
    byte  elementHighDivertToRix;
    short elementLowPhase;  // element (low part) at the effective position
    bool  elementLowEnqueue;
    bool  elementLowFullEmpty;
    bool  elementLowFullEmptyFinished;
    short elementLowRound;
    bool  elementLowDirty;
    byte  elementLowTid;  // (TID of the finish helpee (may be the same or different from the linearization helpee))

    bool isNowFullOrEmpty;  // auxiliary local variables
    bool needReReadReader;
    bool sawElementLowTidAlive;
    byte divertToRixNew;
    bool enqueueEffectiveSkip;
    bool dequeueEffectiveSkip;
    bool elementCasAssert;  // (for assert only)
    short cycles;

get_own_phase :  // run the defined thread operations (Enqueues/Dequeues) one after the other

    atomic
    {
        if
        :: (onlyOneSingleEnqueue) -> threadOpsCount = 1;
        :: (onlyOneSingleDequeue) -> threadOpsCount = 1;
        :: else ->
        {
            if
            :: (0 == ownTid) -> threadOpsCount = THREAD_0_OPS_COUNT;
            :: (1 == ownTid) -> threadOpsCount = THREAD_1_OPS_COUNT;
            :: (2 == ownTid) -> threadOpsCount = THREAD_2_OPS_COUNT;
            :: else -> assert(false);
            fi
        }
        fi

        if
        :: (threadOpsCount == threadOpsIndex) -> goto thread_end;  // all operations finished
        :: else;
        fi

        if
        :: (onlyOneSingleEnqueue) -> ownEnqueue = true;
        :: (onlyOneSingleDequeue) -> ownEnqueue = false;
        :: else ->
        {
            if
            :: (0 == ownTid) -> ownEnqueue = (1 == thread_0_ops[threadOpsIndex]);
            :: (1 == ownTid) -> ownEnqueue = (1 == thread_1_ops[threadOpsIndex]);
            :: (2 == ownTid) -> ownEnqueue = (1 == thread_2_ops[threadOpsIndex]);
            :: else -> assert(false);
            fi
        }
        fi

        /*********************************************
         the actual enqueue/dequeue algorithms
         *********************************************/

        // Obtain (atomically) the next phase (Fetch-And-Add)
        ownPhase = nextPhase;
        nextPhase ++;
        printf("TID %d phase taken: %d\n", ownTid, ownPhase);
    }

write_own_state :

    /*TLWACCH*/

    atomic
    {
        enqueueEffectiveSkip = false;
        dequeueEffectiveSkip = false;
        cycles = 0;

        if
        :: (ownEnqueue) -> printf("TID %d (enqueue, phase: %d) starts\n", ownTid, ownPhase);
        :: else         -> printf("TID %d (dequeue, phase: %d) starts\n", ownTid, ownPhase);
        fi

        assert(false == state[ownTid].pending);
        assert(false == state[ownTid].inProgress);

        // record the new operation into the state array
        // (this must be written atomically, i.e. this is a case for yet another CMPXCHG16B that should also
        // validate the above asserts on inProgress + pending (thus making sure that the TID is not shared
        // by two (or more) threads that would enter the Queue concurrently))

        state[ownTid].value       = ownPhase;  // (in this model: assign the same value as phase for assertion reasons)
        state[ownTid].phase       = ownPhase;
        state[ownTid].enqueue     = ownEnqueue;
        state[ownTid].fullOrEmpty = false;
        state[ownTid].pending     = true;
        state[ownTid].inProgress  = true;

        helpLinearizeTid = ((1 + ownTid) % NUM_THRDS);
    }

read_helpee_state :  // the helping to linearize loop: read the state array

    /*TLWACCH*/

    atomic
    {
        stateValue       = state[helpLinearizeTid].value;
        statePhase       = state[helpLinearizeTid].phase;  // phase of the operation to help linearize
        stateEnqueue     = state[helpLinearizeTid].enqueue;
        stateFullOrEmpty = state[helpLinearizeTid].fullOrEmpty;
        statePending     = state[helpLinearizeTid].pending;
        stateInProgress  = state[helpLinearizeTid].inProgress;

        printf("TID %d helpLinearizeTid %d read state\n", ownTid, helpLinearizeTid);
    }

test_helpee_state :

    /*TLWACCH*/

    atomic
    {
        printf("TID %d test helpLinearizeTid %d phase %d\n", ownTid, helpLinearizeTid, statePhase);

        if
        :: (statePending && (statePhase <= ownPhase)) ->  // pending && phase number lower or equals: yes go help linearize
        {
            if
            :: (stateEnqueue) ->
            {
                if
                :: (false == enqueueEffectiveSkip) -> goto enqueue_read_writer;
                :: else -> goto enqueue_read_reader;
                fi
            }
            :: else ->  // Dequeue
            {
                if
                :: (false == dequeueEffectiveSkip) -> goto dequeue_read_reader;
                :: else -> goto dequeue_read_writer;
                fi
            }
            fi
        }
        :: else ->  // the operation to help linearize is not pending (anymore) or has a higher phase number
        {
            if
            :: (ownTid != helpLinearizeTid) ->  // if not yet reached back "us": switch to the next linearization helpee
            {
                helpLinearizeTid = ((1 + helpLinearizeTid) % NUM_THRDS);
                goto read_helpee_state;
            }
            :: else ->  // if reached back "us": finish the operation
            {
                if
                :: (ownEnqueue && state[ownTid].fullOrEmpty) -> printf("TID %d (enqueue) finished: full\n", ownTid);
                :: (ownEnqueue && (false == state[ownTid].fullOrEmpty)) -> printf("TID %d (enqueue) finished: value %d\n", ownTid, state[ownTid].value);
                :: ((false == ownEnqueue) && state[ownTid].fullOrEmpty) -> printf("TID %d (dequeue) finished: empty\n", ownTid);
                :: ((false == ownEnqueue) && (false == state[ownTid].fullOrEmpty)) -> printf("TID %d (dequeue) finished: value %d\n", ownTid, state[ownTid].value);
                fi

                assert(false == state[ownTid].pending);
                assert(true == state[ownTid].inProgress);

                state[ownTid].inProgress = false;

                threadOpsIndex ++;

                goto get_own_phase;  // next operation
            }
            fi
        }
        fi
        assert(false);  // this spot must not be reached
    }

    //  _  _ ____ _    ___     _    _ _  _ ____ ____ ____ _ ___  ____
    //  |__| |___ |    |__]    |    | |\ | |___ |__| |__/ |   /  |___
    //  |  | |___ |___ |       |___ | | \| |___ |  | |  \ |  /__ |___

enqueue_read_writer :  // the Enqueue path

    /*TLWACCH*/

    // read the writer position
    atomic
    {
        origEffectiveRound = writerPositionRound;
        origEffectiveRix   = writerPositionRix;
        origEffectiveIx    = writerPositionIx;
        printf("TID %d helpLinearizeTid %d (enqueue) has read writerPosition (%d,%d,%d)\n", ownTid, helpLinearizeTid, origEffectiveRound, origEffectiveRix, origEffectiveIx);
        effectiveRound = origEffectiveRound;
        effectiveRix   = origEffectiveRix;
        effectiveIx    = origEffectiveIx;

        assert(effectiveIx < (FIRST_ARRAY_SIZE << effectiveRix));
    }

enqueue_read_reader :

    /*TLWACCH*/

    // read the reader position
    atomic
    {
        oppositeRound = readerPositionRound;
        oppositeRix   = readerPositionRix;
        oppositeIx    = readerPositionIx;
        printf("TID %d helpLinearizeTid %d (enqueue) has read readerPosition (%d,%d,%d)\n", ownTid, helpLinearizeTid, oppositeRound, oppositeRix, oppositeIx);

        assert(oppositeIx < (FIRST_ARRAY_SIZE << oppositeRix));
        assert(effectiveRound <= (1 + oppositeRound));
    }

enqueue_read_element_low :

    /*TLWACCH*/

    // read the element (the low part) at the writer position
    atomic
    {
        isNowFullOrEmpty = false;
        needReReadReader = false;
        sawElementLowTidAlive = false;
        divertToRixNew = 0;
        enqueueEffectiveSkip = false;
        dequeueEffectiveSkip = false;
        elementCasAssert = true;

        cycles ++; assert(cycles <= 8);  // just an assert to detect excessive cycles

        assert(effectiveIx < ringsAllocMemory[effectiveRix]);  // check that the array is allocated and we are not out of its bounds

        elementLowPhase             = rings[effectiveRix].elements[effectiveIx].lowPhase;
        elementLowEnqueue           = rings[effectiveRix].elements[effectiveIx].lowEnqueue;
        elementLowFullEmpty         = rings[effectiveRix].elements[effectiveIx].lowFullEmpty;
        elementLowFullEmptyFinished = rings[effectiveRix].elements[effectiveIx].lowFullEmptyFinished;
        elementLowRound             = rings[effectiveRix].elements[effectiveIx].lowRound;
        elementLowDirty             = rings[effectiveRix].elements[effectiveIx].lowDirty;
        elementLowTid               = rings[effectiveRix].elements[effectiveIx].lowTid;

        assert((effectiveRound <= (1 + elementLowRound)) || (false == elementLowDirty));

        if
        :: (elementLowFullEmpty && (false == elementLowFullEmptyFinished)) ->  // element contains not-yet-finished state full/empty
        {
            if
            :: (statePhase != elementLowPhase) ->
            {
                printf("TID %d helpLinearizeTid %d (enqueue) going to help a different operation (tid %d phase %d) finish full/empty\n", ownTid, helpLinearizeTid, elementLowTid, elementLowPhase);
                goto help_full_empty_re_read_state;  // re-reading from state is needed
            }
            :: else ->
            {
                printf("TID %d helpLinearizeTid %d (enqueue) going to help the operation finish full/empty\n", ownTid, helpLinearizeTid);
                goto help_full_empty_cas_state;
            }
            fi
        }
        // (elementLowFullEmpty && elementLowFullEmptyFinished) is good for going forward
        :: else;
        fi

        if
        // if the writer position is in its transient state (or lagging even more)
        :: ((effectiveRound != (1 + elementLowRound)) && elementLowDirty) ->
        {
            printf("TID %d helpLinearizeTid %d (enqueue) transient/lagging state in rings[%d][%d]\n", ownTid, helpLinearizeTid, effectiveRix, effectiveIx);

            // Asserts for the transient state of the writer:
            // A: Linearization of the full/empty state does not lead to the transient state.
            // B: In the transient state of the writer it is impossible that the reader position is "now" here in the previous round,
            // because the Enqueue would have helped the reader move (to its stationary state) before own linearizing.
            // (Note: How do we distinguish transient from lagging even more? At the time of reading the writer position
            // it was either transient or stationary. If it has not moved up to here (test below), then it can "now" be only transient.)
            if
            :: ((effectiveRound == writerPositionRound) && (effectiveRix == writerPositionRix) && (effectiveIx == writerPositionIx)) ->
            {
                assert(false == elementLowFullEmpty);
                assert((effectiveRound != (1 + readerPositionRound)) || (effectiveRix != readerPositionRix) || (effectiveIx != readerPositionIx));
            }
            :: else;
            fi

            // align the effective position (more precisely: only its round) to the successful linearizer
            if
            :: (effectiveRound != elementLowRound) ->
            {
                printf("TID %d helpLinearizeTid %d aligning effective position round to %d\n", ownTid, helpLinearizeTid, elementLowRound);
                origEffectiveRound = elementLowRound;
                effectiveRound = elementLowRound;
            }
            :: else;
            fi

            if
            :: (elementLowEnqueue) ->  // the last linearized operation on that element was Enqueue
            {
                if
                :: (statePhase != elementLowPhase) ->
                {
                    printf("TID %d helpLinearizeTid %d (enqueue) going to help finish a different Enqueue operation (tid %d phase %d)\n", ownTid, helpLinearizeTid, elementLowTid, elementLowPhase);
                    goto help_finish_re_read_state;  // re-reading from state is needed
                }
                :: else ->
                {
                    printf("TID %d helpLinearizeTid %d (enqueue) going to help finish the operation\n", ownTid, helpLinearizeTid);
                    goto help_finish_read_element_high;
                }
                fi
            }
            :: else ->  // the last linearized operation on that element was Dequeue (i.e. an opposite operation)
            {
                printf("TID %d helpLinearizeTid %d (enqueue) going to help finish a Dequeue operation (tid %d phase %d)\n", ownTid, helpLinearizeTid, elementLowTid, elementLowPhase);

                // As the Dequeue finish helping does not need the "opposite" position, the reading order writer -> reader
                // causes no harm and so no re-reading of the reader is needed.

                goto help_finish_re_read_state;  // re-reading from state is needed
            }
            fi
        }
        :: else ->  // the writer is in its stationary state
        {
            printf("TID %d helpLinearizeTid %d (enqueue) stationary state in rings[%d][%d]\n", ownTid, helpLinearizeTid, effectiveRix, effectiveIx);
            if
            :: (elementLowDirty && elementLowEnqueue) ->  // the last linearized operation on that element was Enqueue: Queue is full
            {
                assert(0 != ringsAllocMemory[CNT_ALLOWED_EXTENSIONS]);  // Queue full can happen only in the fully-extended state
                assert(effectiveRound == (1 + elementLowRound));

                // This is a candidate linearization point for "Queue is full", so the following assert must hold.
                // This candidate LP however cannot be directly utilized, because here (unlike in the Lock-Free Queue)
                // a thread is not solely responsible for own linearizations: Here that responsibility is shared,
                // so if this candidate LP were directly utilized to return "Queue is full", a race could happen
                // between thread(s) that see the Queue full and thread(s) which don't (that would attempt to indeed linearize
                // the Enqueue). Instead, the "Queue is full" condition must be signalled (via the local isNowFullOrEmpty boolean)
                // to the "central LP" (which is the CAS on element (low)).

                assert(MAXIMUM_CAPACITY == (cntEnqueued - cntDequeued));

                // Handling of Queue full is described in the Linearization section.
                //
                // Question: Is it safe to linearize (from the perspective whether the previous linearized operation is already finished)?
                // Answer yes: The previous operation was Enqueue and we are now in stationary state of the writer in the next round.
                // (An eventual pre-existing not-yet-finished full/empty was handled above.)

                printf("TID %d helpLinearizeTid %d (enqueue) going to linearize full/empty\n", ownTid, helpLinearizeTid);
                isNowFullOrEmpty = true;
                goto re_check_state_pending;
            }
            :: (elementLowDirty && (false == elementLowEnqueue)) ->  // the last linearized operation on that element was Dequeue
            {
                // Question: Is it safe to linearize (from the perspective whether the previous linearized operation is already finished)?
                // Answer: Yes except when the reader is there (in which case we have to help him move away to its stationary state).
                // (An eventual pre-existing not-yet-finished full/empty was handled above.)

                if
                :: ((effectiveRound == (1 + oppositeRound)) && (effectiveRix == oppositeRix) && (effectiveIx == oppositeIx)) ->
                {
                    printf("TID %d helpLinearizeTid %d (enqueue) going to first help finish Dequeue (tid %d phase %d) to its stationary state\n", ownTid, helpLinearizeTid, elementLowTid, elementLowPhase);

                    assert(0 != ringsAllocMemory[CNT_ALLOWED_EXTENSIONS]);  // this can happen only in the fully-extended state

                    // writer position has higher round than reader position, so round alignment is needed.
                    origEffectiveRound = oppositeRound;
                    effectiveRound = oppositeRound;

                    // And: as the Dequeue finish helping does not need the "opposite" position, the reading order writer -> reader
                    // causes no harm and so no re-reading of the reader is needed.

                    goto help_finish_re_read_state;  // re-reading from state is needed
                }
                :: else ->  // the main-stream case
                {
                    printf("TID %d helpLinearizeTid %d (enqueue) going to linearize the operation\n", ownTid, helpLinearizeTid);
                    goto re_check_state_pending;
                }
                fi
            }
            :: else ->  // there was no operation yet on that element (i.e. the element is clean)
            {
                // Question: Is it safe to linearize (from the perspective whether the previous linearized operation is already finished)?
                // Answer yes: The element is clean and an eventual pre-existing not-yet-finished full/empty was handled above.

                printf("TID %d helpLinearizeTid %d (enqueue) going to linearize the operation (element is clean)\n", ownTid, helpLinearizeTid);
                goto re_check_state_pending;
            }
            fi
        }
        fi
        assert(false);  // this spot must not be reached
    }

dequeue_read_reader :  // the Dequeue path

    /*TLWACCH*/

    // read the reader position
    atomic
    {
        origEffectiveRound = readerPositionRound;
        origEffectiveRix   = readerPositionRix;
        origEffectiveIx    = readerPositionIx;
        printf("TID %d helpLinearizeTid %d (dequeue) has read readerPosition (%d,%d,%d)\n", ownTid, helpLinearizeTid, origEffectiveRound, origEffectiveRix, origEffectiveIx);
        effectiveRound = origEffectiveRound;
        effectiveRix   = origEffectiveRix;
        effectiveIx    = origEffectiveIx;

        assert(effectiveIx < (FIRST_ARRAY_SIZE << effectiveRix));
    }

dequeue_read_writer :

    /*TLWACCH*/

    // read the writer position
    atomic
    {
        oppositeRound = writerPositionRound;
        oppositeRix   = writerPositionRix;
        oppositeIx    = writerPositionIx;
        printf("TID %d helpLinearizeTid %d (dequeue) has read writerPosition (%d,%d,%d)\n", ownTid, helpLinearizeTid, oppositeRound, oppositeRix, oppositeIx);

        assert(oppositeIx < (FIRST_ARRAY_SIZE << oppositeRix));
        assert(effectiveRound <= oppositeRound);
    }

dequeue_read_element_low :

    /*TLWACCH*/

    // read the element (the low part) at the reader position
    atomic
    {
        isNowFullOrEmpty = false;
        needReReadReader = false;
        sawElementLowTidAlive = false;
        divertToRixNew = 0;
        enqueueEffectiveSkip = false;
        dequeueEffectiveSkip = false;
        elementCasAssert = true;

        cycles ++; assert(cycles <= 8);  // just an assert to detect excessive cycles

        assert(effectiveIx < ringsAllocMemory[effectiveRix]);  // check that the array is allocated and we are not out of its bounds

        elementLowPhase             = rings[effectiveRix].elements[effectiveIx].lowPhase;
        elementLowEnqueue           = rings[effectiveRix].elements[effectiveIx].lowEnqueue;
        elementLowFullEmpty         = rings[effectiveRix].elements[effectiveIx].lowFullEmpty;
        elementLowFullEmptyFinished = rings[effectiveRix].elements[effectiveIx].lowFullEmptyFinished;
        elementLowRound             = rings[effectiveRix].elements[effectiveIx].lowRound;
        elementLowDirty             = rings[effectiveRix].elements[effectiveIx].lowDirty;
        elementLowTid               = rings[effectiveRix].elements[effectiveIx].lowTid;

        assert((effectiveRound <= (1 + elementLowRound)) || (false == elementLowDirty));

        if
        :: (elementLowFullEmpty && (false == elementLowFullEmptyFinished)) ->  // element contains not-yet-finished state full/empty
        {
            if
            :: (statePhase != elementLowPhase) ->
            {
                printf("TID %d helpLinearizeTid %d (dequeue) going to help a different operation (tid %d phase %d) finish full/empty\n", ownTid, helpLinearizeTid, elementLowTid, elementLowPhase);
                goto help_full_empty_re_read_state;  // re-reading from state is needed
            }
            :: else ->
            {
                printf("TID %d helpLinearizeTid %d (dequeue) going to help the operation finish full/empty\n", ownTid, helpLinearizeTid);
                goto help_full_empty_cas_state;
            }
            fi
        }
        // (elementLowFullEmpty && elementLowFullEmptyFinished) is good for going forward
        :: else;
        fi

        if
        // if the reader position is in its transient state (or lagging even more)
        // Explanation:
        //   NOT if same round and the last operation was Enqueue (the main-stream case: going to dequeue enqueued elements)
        //   AND NOT if element is one round below (Queue empty)
        //   AND NOT if element is clean (Queue empty)
        :: (((effectiveRound != elementLowRound) || (false == elementLowEnqueue)) && (effectiveRound != (1 + elementLowRound)) && elementLowDirty) ->
        {
            printf("TID %d helpLinearizeTid %d (dequeue) transient/lagging state in rings[%d][%d]\n", ownTid, helpLinearizeTid, effectiveRix, effectiveIx);

            // Asserts for the transient state of the reader:
            // A: Linearization of the full/empty state does not lead to the transient state.
            // B: In the transient state of the reader it is impossible that the writer position is "now" here in the same round,
            // because the Dequeue would have helped the writer move (to its stationary state) before own linearizing.
            // (Note: How do we distinguish transient from lagging even more? At the time of reading the reader position
            // it was either transient or stationary. If it has not moved up to here (test below), then it can "now" be only transient.)
            if
            :: ((effectiveRound == readerPositionRound) && (effectiveRix == readerPositionRix) && (effectiveIx == readerPositionIx)) ->
            {
                assert(false == elementLowFullEmpty);
                assert((effectiveRound != writerPositionRound) || (effectiveRix != writerPositionRix) || (effectiveIx != writerPositionIx));
            }
            :: else;
            fi

            // align the effective position (more precisely: only its round) to the successful linearizer
            if
            :: (effectiveRound != elementLowRound) ->
            {
                printf("TID %d helpLinearizeTid %d aligning effective position round to %d\n", ownTid, helpLinearizeTid, elementLowRound);
                origEffectiveRound = elementLowRound;
                effectiveRound = elementLowRound;
            }
            :: else;
            fi

            if
            :: (elementLowEnqueue) ->  // the last linearized operation on that element was Enqueue (i.e. an opposite operation)
            {
                printf("TID %d helpLinearizeTid %d (dequeue) going to help finish an Enqueue operation (tid %d phase %d)\n", ownTid, helpLinearizeTid, elementLowTid, elementLowPhase);

                // We have read the positions in the order reader -> writer and now we switch to helping an Enqueue
                // (which needs the positions to have been read in the opposite order): do an extra step of re-reading the reader position.

                needReReadReader = true;

                goto help_finish_re_read_state;  // re-reading from state is needed
            }
            :: else ->  // the last linearized operation on that element was Dequeue
            {
                if
                :: (statePhase != elementLowPhase) ->
                {
                    printf("TID %d helpLinearizeTid %d (dequeue) going to help finish a different Dequeue operation (tid %d phase %d)\n", ownTid, helpLinearizeTid, elementLowTid, elementLowPhase);
                    goto help_finish_re_read_state;  // re-reading from state is needed
                }
                :: else ->
                {
                    printf("TID %d helpLinearizeTid %d (dequeue) going to help finish the operation\n", ownTid, helpLinearizeTid);
                    goto help_finish_read_element_high;
                }
                fi
            }
            fi
        }
        :: else ->  // the reader is in its stationary state
        {
            printf("TID %d helpLinearizeTid %d (dequeue) stationary state in rings[%d][%d]\n", ownTid, helpLinearizeTid, effectiveRix, effectiveIx);
            if
            :: (elementLowDirty && elementLowEnqueue) ->  // the last linearized operation on that element was Enqueue
            {
                // Question: Is it safe to linearize (from the perspective whether the previous linearized operation is already finished)?
                // Answer: Yes except when the writer is there (in which case we have to help him move away to its stationary state)
                // (An eventual pre-existing not-yet-finished full/empty was handled above.)

                if
                :: ((effectiveRound == oppositeRound) && (effectiveRix == oppositeRix) && (effectiveIx == oppositeIx)) ->
                {
                    printf("TID %d helpLinearizeTid %d (dequeue) going to first help finish Enqueue (tid %d phase %d) to its stationary state\n", ownTid, helpLinearizeTid, elementLowTid, elementLowPhase);

                    // the rounds match, so no round alignment is needed

                    // But: We have read the positions in the order reader -> writer and now we switch to helping an Enqueue
                    // (which needs the positions to have been read in opposite order): do an extra step of re-reading the reader position.

                    needReReadReader = true;

                    goto help_finish_re_read_state;  // re-reading from state is needed
                }
                :: else ->  // the main-stream case
                {
                    printf("TID %d helpLinearizeTid %d (dequeue) going to linearize the operation\n", ownTid, helpLinearizeTid);
                    goto re_check_state_pending;
                }
                fi
            }
            // if the last linearized operation on that element was Dequeue: Queue is empty
            :: (elementLowDirty && (false == elementLowEnqueue)) ->
            {
                assert(effectiveRound == (1 + elementLowRound));

                // This is a candidate linearization point for "Queue is empty", so the following assert must hold.
                // This candidate LP however cannot be directly utilized, because here (unlike in the Lock-Free Queue)
                // a thread is not solely responsible for own linearizations: Here that responsibility is shared,
                // so if this candidate LP were directly utilized to return "Queue is empty", a race could happen
                // between thread(s) that see the Queue empty and thread(s) which don't (that would attempt to indeed linearize
                // the Dequeue). Instead, the "Queue is empty" condition must be signalled (via the local isNowFullOrEmpty boolean)
                // to the "central LP" (which is the CAS on element (low)).

                assert(cntEnqueued == cntDequeued);

                // Handling of Queue empty is described in the Linearization section.
                //
                // Question: Is it safe to linearize (from the perspective whether the previous linearized operation is already finished)?
                // Answer yes: The previous operation was Dequeue and we are now in stationary state of the reader in the next round.
                // (An eventual pre-existing not-yet-finished full/empty was handled above.)

                printf("TID %d helpLinearizeTid %d (dequeue) going to linearize full/empty\n", ownTid, helpLinearizeTid);
                isNowFullOrEmpty = true;
                goto re_check_state_pending;
            }
            :: else ->  // there was no operation yet on that element (i.e. the element is clean): Queue is empty
            {
                // (same remark about candidate LP for "Queue is empty" as above)
                assert(cntEnqueued == cntDequeued);

                // Handling of Queue empty is described in the Linearization section.
                //
                // Question: Is it safe to linearize (from the perspective whether the previous linearized operation is already finished)?
                // Answer yes: The element is clean and an eventual pre-existing not-yet-finished full/empty was handled above.

                printf("TID %d helpLinearizeTid %d (dequeue) going to linearize full/empty (element is clean)\n", ownTid, helpLinearizeTid);
                isNowFullOrEmpty = true;
                goto re_check_state_pending;
            }
            fi
        }
        fi
        assert(false);  // this spot must not be reached
    }

re_check_state_pending :

    /*TLWACCH*/

    // We are now in the stationary state of the writer (or reader), which means that all respective helping must now be finished
    // (which would include the writing back to the state array). So we now must confirm that the operation which we are going to linearize
    // is still in the state array && pending. The confirmation that no other Enqueue (or Dequeue) linearization occurred in between
    // will be given by the success of the linearization CAS in cas_element_low.

    atomic
    {
        assert(false == stateFullOrEmpty);  // follows from above
        assert(true == statePending);
        assert(true == stateInProgress);

        if
        :: ((stateValue       == state[helpLinearizeTid].value)
         && (statePhase       == state[helpLinearizeTid].phase)
         && (stateEnqueue     == state[helpLinearizeTid].enqueue)
         && (stateFullOrEmpty == state[helpLinearizeTid].fullOrEmpty)
         && (statePending     == state[helpLinearizeTid].pending)
         && (stateInProgress  == state[helpLinearizeTid].inProgress)) ->
        {
            printf("TID %d helpLinearizeTid %d state re-check OK\n", ownTid, helpLinearizeTid);
            goto cas_element_low;
        }
        :: else ->
        {
            printf("TID %d helpLinearizeTid %d state re-check NOK\n", ownTid, helpLinearizeTid);

            // The discrepancy could have been caused only by the current operation not pending anymore, or by a new operation
            assert((false == state[helpLinearizeTid].pending) || (statePhase < state[helpLinearizeTid].phase));

            stateValue       = state[helpLinearizeTid].value;
            statePhase       = state[helpLinearizeTid].phase;
            stateEnqueue     = state[helpLinearizeTid].enqueue;
            stateFullOrEmpty = state[helpLinearizeTid].fullOrEmpty;
            statePending     = state[helpLinearizeTid].pending;
            stateInProgress  = state[helpLinearizeTid].inProgress;

            // This means that the operation has in between been linearized and helped up to the state array CAS,
            // so we must not linearize it again. We do not know if the operation was linearized at our effective position
            // or elsewhere. To help finish the old value at the element does not make sense either, because it was read
            // in the stationary state (i.e. all helping finished). So it only makes sense to start again
            // (+ the state for helpLinearizeTid has been read just above (the full 16 bytes),
            // so no need to read it again: go to test_helpee_state).

            goto test_helpee_state;
        }
        fi
    }

cas_element_low :

    /*TLWACCH*/

    // try the element (low part) CAS to linearize (16-byte CAS)
    atomic
    {
        if
        :: ((elementLowPhase             == rings[effectiveRix].elements[effectiveIx].lowPhase)
         && (elementLowEnqueue           == rings[effectiveRix].elements[effectiveIx].lowEnqueue)
         && (elementLowFullEmpty         == rings[effectiveRix].elements[effectiveIx].lowFullEmpty)
         && (elementLowFullEmptyFinished == rings[effectiveRix].elements[effectiveIx].lowFullEmptyFinished)
         && (elementLowRound             == rings[effectiveRix].elements[effectiveIx].lowRound)
         && (elementLowDirty             == rings[effectiveRix].elements[effectiveIx].lowDirty)
         && (elementLowTid               == rings[effectiveRix].elements[effectiveIx].lowTid)) ->
        {
            // the element (low part) CAS succeeded
            sawElementLowTidAlive = true;

            if
            :: (isNowFullOrEmpty) ->
            {
                // Full means hitting a linearized Enqueue in the previous round
                // and empty means hitting a linearized Dequeue in the previous round
                // (or no operation yet (which fortunately implies false == lowEnqueue)).
                assert(stateEnqueue == rings[effectiveRix].elements[effectiveIx].lowEnqueue);
                assert((effectiveRound == (1 + elementLowRound)) || (false == elementLowDirty));
            }
            :: else;
            fi

            rings[effectiveRix].elements[effectiveIx].lowPhase             = statePhase;
            rings[effectiveRix].elements[effectiveIx].lowEnqueue           = stateEnqueue;
            rings[effectiveRix].elements[effectiveIx].lowFullEmpty         = isNowFullOrEmpty;
            rings[effectiveRix].elements[effectiveIx].lowFullEmptyFinished = false;
            rings[effectiveRix].elements[effectiveIx].lowRound             = (isNowFullOrEmpty -> elementLowRound : effectiveRound);
            rings[effectiveRix].elements[effectiveIx].lowDirty             = (isNowFullOrEmpty -> elementLowDirty : true);
            rings[effectiveRix].elements[effectiveIx].lowTid               = helpLinearizeTid;

            elementLowPhase             = statePhase;
            elementLowEnqueue           = stateEnqueue;
            elementLowFullEmpty         = isNowFullOrEmpty;
            elementLowFullEmptyFinished = false;
            elementLowRound             = (isNowFullOrEmpty -> elementLowRound : effectiveRound);
            elementLowDirty             = (isNowFullOrEmpty -> elementLowDirty : true);
            elementLowTid               = helpLinearizeTid;

            // success of the element (low part) CAS is the linearization point
            if
            :: (stateEnqueue) ->
            {
                if
                :: (isNowFullOrEmpty) ->
                {
                    cntEnqueueFull ++;
                    printf("TID %d helpLinearizeTid %d linearized Enqueue with isNowFullOrEmpty in rings[%d][%d]\n", ownTid, helpLinearizeTid, effectiveRix, effectiveIx);
                    assert(MAXIMUM_CAPACITY == (cntEnqueued - cntDequeued));
                }
                :: else ->
                {
                    // capture stateValue in array linearizationOrder
                    linearizationOrder[cntEnqueued] = stateValue;  // (for assert only, not for the real code)
                    cntEnqueued ++;
                    printf("TID %d helpLinearizeTid %d linearized Enqueue with value %d in rings[%d][%d]\n", ownTid, helpLinearizeTid, stateValue, effectiveRix, effectiveIx);
                }
                fi
            }
            :: else ->  // Dequeue
            {
                if
                :: (isNowFullOrEmpty) ->
                {
                    cntDequeueEmpty ++;
                    printf("TID %d helpLinearizeTid %d linearized Dequeue with isNowFullOrEmpty in rings[%d][%d]\n", ownTid, helpLinearizeTid, effectiveRix, effectiveIx);
                    assert(cntEnqueued == cntDequeued);
                }
                :: else ->
                {
                    // verify the correct FIFO order via array linearizationOrder
                    assert(linearizationOrder[cntDequeued] == rings[effectiveRix].elements[effectiveIx].highValue);
                    cntDequeued ++;
                    printf("TID %d helpLinearizeTid %d linearized Dequeue with value %d in rings[%d][%d]\n", ownTid, helpLinearizeTid, rings[effectiveRix].elements[effectiveIx].highValue, effectiveRix, effectiveIx);
                }
                fi
            }
            fi

            if
            :: (isNowFullOrEmpty) -> goto help_full_empty_cas_state;  // finish Queue full/empty
            :: else -> goto help_finish_read_element_high;  // otherwise continue towards the element (high part) CAS
            fi
        }
        :: else ->  // the element (low part) CAS failed, get the current element value (this still goes atomically with CMPXCHG16B)
        {
            printf("TID %d helpLinearizeTid %d linearization failed in rings[%d][%d]\n", ownTid, helpLinearizeTid, effectiveRix, effectiveIx);

            elementLowPhase             = rings[effectiveRix].elements[effectiveIx].lowPhase;
            elementLowEnqueue           = rings[effectiveRix].elements[effectiveIx].lowEnqueue;
            elementLowFullEmpty         = rings[effectiveRix].elements[effectiveIx].lowFullEmpty;
            elementLowFullEmptyFinished = rings[effectiveRix].elements[effectiveIx].lowFullEmptyFinished;
            elementLowRound             = rings[effectiveRix].elements[effectiveIx].lowRound;
            elementLowDirty             = rings[effectiveRix].elements[effectiveIx].lowDirty;
            elementLowTid               = rings[effectiveRix].elements[effectiveIx].lowTid;

            // Asserts study to understand "who could have caused the linearization CAS to fail"
            if
            :: (elementLowFullEmpty) ->  // a full/empty linearization by somebody else
            {
                if
                :: (elementLowEnqueue) ->  // in Enqueue (i.e. "full")
                {
                    // the element can only be dirty and the linearization kept the original (one below) round
                    assert((effectiveRound <= (1 + elementLowRound)) && elementLowDirty);
                }
                :: else ->  // in Dequeue (i.e. "empty")
                {
                    // the linearization kept the original (one below) round and the original dirty flag
                    assert((effectiveRound <= (1 + elementLowRound)) || (false == elementLowDirty));
                }
                fi
            }
            :: else ->  // a regular (not full/empty) linearization by somebody else
            {
                if
                :: (stateEnqueue && isNowFullOrEmpty) ->  // we saw full and wanted to linearize it
                {
                    // a Dequeue in the previous round might have been linearized instead
                    assert((effectiveRound <= (1 + elementLowRound)) && elementLowDirty);
                }
                :: ((false == stateEnqueue) && isNowFullOrEmpty) ->  // we saw empty and wanted to linearize it
                {
                    // empty: An Enqueue in the same round might have been linearized instead
                    assert((effectiveRound <= elementLowRound) && elementLowDirty);
                }
                :: else ->  // we wanted a regular (not full/empty) linearization
                {
                    // the linearization must have been at least with the same round number as "ours"
                    assert((effectiveRound <= elementLowRound) && elementLowDirty);
                }
                fi
            }
            fi

            // Now: The indeed linearized operation could be the intended operation, or another operation of the same type,
            // or an operation of a different type (Enqueue vs Dequeue). The last eventuality would mean that the
            // Queue has moved in the meantime rather substantially in the sense that we have found a linearized Dequeue
            // on our copy of the writer position or vice versa. In the most extreme case our copy of the writer/reader
            // position may lag by one or more rounds.
            //
            // But anyway, we try to help in all cases, because the helping scheme is safe in the sense that
            // no helping step of no operation can succeed if it already has succeeded once.

            if
            // the operation linearized by somebody else was full/empty (and the full/empty helping is not yet finished)
            :: (elementLowFullEmpty && (false == elementLowFullEmptyFinished)) ->
            {
                if
                :: (statePhase != elementLowPhase) ->  // the operation linearized by somebody else is not our intended operation
                {
                    goto help_full_empty_re_read_state;  // re-reading from state is needed
                }
                :: else ->  // is our intended operation
                {
                    goto help_full_empty_cas_state;
                }
                fi
            }
            // the operation linearized by somebody else was full/empty (and the full/empty helping is already finished)
            :: (elementLowFullEmpty && elementLowFullEmptyFinished) ->
            {
                // assert that the state array is not pending anymore or contains already a new operation
                assert((false == state[elementLowTid].pending) || (elementLowPhase < state[elementLowTid].phase));

                goto read_helpee_state;  // no more helping makes sense, start again
            }
            :: else;
            fi

            // the regular case (not full/empty)

            // align the effective position (more precisely: only its round) to the successful linearizer
            if
            :: (effectiveRound != elementLowRound) ->
            {
                printf("TID %d helpLinearizeTid %d aligning effective position round to %d\n", ownTid, helpLinearizeTid, elementLowRound);
                origEffectiveRound = elementLowRound;
                effectiveRound = elementLowRound;
            }
            :: else;
            fi

            // If we intended to help a Dequeue (i.e. have read the positions in the order reader -> writer)
            // and now we switch to helping an Enqueue (which needs the positions to be read in the opposite order),
            // do an extra step of re-reading the reader position.
            if
            :: ((false == stateEnqueue) && (elementLowEnqueue)) ->
            {
                printf("TID %d helpLinearizeTid %d switching to help Enqueue elementLowTid %d\n", ownTid, helpLinearizeTid, elementLowTid);

                needReReadReader = true;
            }
            :: ((stateEnqueue) && (false == elementLowEnqueue)) ->
            {
                printf("TID %d helpLinearizeTid %d switching to help Dequeue elementLowTid %d\n", ownTid, helpLinearizeTid, elementLowTid);
            }
            :: else;
            fi

            if
            :: (statePhase != elementLowPhase) ->  // the operation linearized by somebody else is not our intended operation
            {
                goto help_finish_re_read_state;  // re-reading from state is needed
            }
            :: else ->  // is our intended operation
            {
                goto help_finish_read_element_high;
            }
            fi
        }
        fi
        assert(false);  // this spot must not be reached
    }

    //  _  _ ____ _    ___     ____ _ _  _ _ ____ _  _
    //  |__| |___ |    |__]    |___ | |\ | | [__  |__|
    //  |  | |___ |___ |       |    | | \| | ___] |  |

    // The concept: the linearization (either own (CAS success) or foreign (CAS fail)) was the decision about an operation
    // (either Enqueue or Dequeue) and the subsequent "help" program codes care (only) about the respective finishing.

help_finish_re_read_state :

    /*TLWACCH*/

    // re-read the state record

    // jump into here if the element (low part) contains the linearized operation to be finished that is different
    // from the operation that was intended for linearization (i.e. re-reading from state is needed)

    // note: A helper thread will not help linearize a helpee operation if its phase is higher than own phase.
    // For helping to finish this is however well possible.

    atomic
    {
        assert(statePhase != elementLowPhase);  // follows from above (new statePhase will be read below)

        stateValue       = state[elementLowTid].value;
        statePhase       = state[elementLowTid].phase;
        stateEnqueue     = state[elementLowTid].enqueue;
        stateFullOrEmpty = state[elementLowTid].fullOrEmpty;
        statePending     = state[elementLowTid].pending;
        stateInProgress  = state[elementLowTid].inProgress;

        printf("TID %d helpLinearizeTid %d elementLowTid %d: re-read state\n", ownTid, helpLinearizeTid, elementLowTid);

        assert(elementLowPhase <= statePhase);

        // (other evaluations are immersed into the next atomic step (because elementHighDivertToRix is needed for them))
    }

help_finish_read_element_high :

    /*TLWACCH*/

    // read the element (high part) at the effective position

    // jump into here if the element (low part) contains the linearized operation to be finished
    // and it is the operation that was intended for linearization (i.e. no re-reading from state is needed)

    atomic
    {
        elementHighValue       = rings[effectiveRix].elements[effectiveIx].highValue;
        elementHighRound       = rings[effectiveRix].elements[effectiveIx].highRound;
        elementHighDirty       = rings[effectiveRix].elements[effectiveIx].highDirty;
        elementHighDivertToRix = rings[effectiveRix].elements[effectiveIx].highDivertToRix;

        printf("TID %d helpLinearizeTid %d elementLowTid %d has read element (high) rings[%d][%d]\n", ownTid, helpLinearizeTid, elementLowTid, effectiveRix, effectiveIx);

        if
        :: (elementLowPhase != statePhase) ->
        {
            // If the state record contains already a new operation, then the only helping that might succeed
            // is going forward with the writer/reader position and trying to CAS it.
            //
            // For this, it is important that we "know" the correct elementHighDivertToRix.
            // Let's distinguish two possibilities:
            //
            // A) Our copy of the writer position is "now" still the same as in memory.
            //    But then we have the correct elementHighDivertToRix, because we must have read the already linearized element (high)
            //    including the eventual new diversion (which is in elementHighDivertToRix)
            //    (remember: state was read before element (high)).
            //
            // B) Our copy of the writer position is "now" outdated: Then our writer/reader position CAS will fail.
            //    In the extension helping we will either help if we already "know" a non-zero elementHighDivertToRix
            //    or not help if we "know" zero (as the only possible old value).

            printf("TID %d helpLinearizeTid %d elementLowTid %d state record contains already a new operation\n", ownTid, helpLinearizeTid, elementLowTid);
            goto help_finish_extension;
        }
        :: else;
        fi

        assert(elementLowEnqueue == stateEnqueue);

        if
        :: (false == statePending) ->
        {
            // If the pending flag in the state array is already switched off, then the only helping that might succeed
            // is going forward with the writer/reader position and trying to CAS it.
            //
            // Regarding the correct elementHighDivertToRix a similar argumentation as above applies.

            printf("TID %d helpLinearizeTid %d elementLowTid %d operation not pending anymore\n", ownTid, helpLinearizeTid, elementLowTid);
            goto help_finish_extension;
        }
        :: else;
        fi

        if
        :: (elementLowEnqueue) ->  // Enqueue was the operation linearized in the element (low part)
        {
            assert((effectiveRound <= (1 + elementHighRound)) || (false == elementHighDirty));

            if
            :: ((effectiveRound != (1 + elementHighRound)) && elementHighDirty) ->  // we are lagging behind elementHighRound
            {
                // This means that the CAS on element (high part) has been already done by another thread
                // or eventually an Enqueue in the next round has already rolled over the element.
                // The former possibility bears a chance for other helping steps to succeed.
                //
                // For this, it is important that we "know" the correct elementHighDivertToRix.
                // Let's distinguish two possibilities:
                //
                // A) Our copy of the writer position is "now" still the same as in memory.
                //    But then we have the correct elementHighDivertToRix, because we must have read the already linearized element (high)
                //    including the eventual new diversion (which is in elementHighDivertToRix)
                //    (remember: we are lagging behind elementHighRound).
                //
                // B) Our copy of the writer position is "now" outdated: Then our writer/reader position CAS will fail.
                //    In the extension helping we will either help if we already "know" a non-zero elementHighDivertToRix
                //    or not help if we "know" zero (as the only possible old value).

                printf("TID %d helpLinearizeTid %d elementLowTid %d (enqueue) lagging behind elementHighRound\n", ownTid, helpLinearizeTid, elementLowTid);
                goto help_finish_cas_state;
            }
            :: else ->  // we are not lagging: go ahead towards the CAS on element (high part)
            {
                if
                :: (needReReadReader) -> goto help_finish_re_read_reader;
                :: else -> goto help_finish_check_if_new_diversion;
                fi
            }
            fi
        }
        :: else ->  // Dequeue was the operation linearized in the element (low part)
        {
            assert(true == elementHighDirty);
            assert(effectiveRound <= elementHighRound);

            if
            :: (effectiveRound != elementHighRound) ->  // we are lagging behind elementHighRound
            {
                // This means that an Enqueue in the next round has already rolled over the element: no helping makes sense
                // because the Dequeue operation must then be already finished.

                printf("TID %d helpLinearizeTid %d elementLowTid %d (dequeue) lagging behind elementHighRound\n", ownTid, helpLinearizeTid, elementLowTid);
                assert((false == state[elementLowTid].pending) || (elementLowPhase < state[elementLowTid].phase));
                goto read_helpee_state;
            }
            :: else ->  // we are not lagging: elementHighValue + elementHighDivertToRix were successfully read:
            {
                goto help_finish_cas_state;  // go ahead to the CAS on the state array and then to the reader position CAS
            }
            fi
        }
        fi
        assert(false);  // this spot must not be reached
    }

help_finish_re_read_reader :

    /*TLWACCH*/

    // re-read the reader position into "opposite"
    atomic
    {
        assert(true == elementLowEnqueue);  // follows from above

        oppositeRound = readerPositionRound;
        oppositeRix   = readerPositionRix;
        oppositeIx    = readerPositionIx;
        printf("TID %d helpLinearizeTid %d elementLowTid %d has re-read readerPosition (%d,%d,%d)\n", ownTid, helpLinearizeTid, elementLowTid, oppositeRound, oppositeRix, oppositeIx);

        assert(oppositeIx < (FIRST_ARRAY_SIZE << oppositeRix));
        assert(effectiveRound <= (1 + oppositeRound));
    }

help_finish_check_if_new_diversion :

    /*TLWACCH*/

    // if no diversion on the element: check if one shouldn't be added
    // the output of this is divertToRixNew (used by the element (high) CAS that follows)

    assert(elementLowEnqueue);  // follows from above

    if
    :: (0 == elementHighDivertToRix) ->
    {
        atomic
        {
            // The logic of the following loops is: We are now on an element without a diversion. If there is a risk
            // that the Queue might get stuck due to the writer hitting the reader (in the previous round) "from behind"
            // when the Queue is not yet fully extended, then we have to act "now" (in the sense of extending
            // the Queue "now")!

            byte  testNextWriterRix = effectiveRix;
            short testNextWriterIx  = (1 + effectiveIx);  // the projected next step

            // So we make a projected next step. First we handle the situation that this goes beyond the end of the ring.
            // If so, we go the diversion returns back (a cascade is possible).
            // No hitting the reader is possible here, because the reader cannot sit at (FIRST_ARRAY_SIZE << rix) == ix.

            do
            :: ((FIRST_ARRAY_SIZE << testNextWriterRix) == testNextWriterIx) ->  // if beyond the end of the ring
            {
                if
                :: (0 == testNextWriterRix) ->  // the return from the end of rings[0] to rings[0][0] is implicit
                {
                    testNextWriterRix = 0;  // move to rings[0][0]
                    testNextWriterIx  = 0;
                    printf("TID %d helpLinearizeTid %d elementLowTid %d extend Queue checking implicit return to rings[0][0]\n", ownTid, helpLinearizeTid, elementLowTid);
                    break;
                }
                :: else ->  // follow the diversion back (the diversions entries must exist, no need for extra TLWACCHes)
                {
                    byte tmpRix = testNextWriterRix;
                    testNextWriterRix = diversions[tmpRix - 1].rix;
                    testNextWriterIx  = (1 + diversions[tmpRix - 1].ix);
                    printf("TID %d helpLinearizeTid %d elementLowTid %d extend Queue checking real diversion return (%d)\n", ownTid, helpLinearizeTid, elementLowTid, testNextWriterRix);
                }
                fi
            }
            :: else -> break;
            od

            // Once the diversion returns phase is over (or has never begun), we start testing for hitting the reader
            // "from behind" and go eventual diversions forward (a cascade is possible here too).
            // As long as we go, the "risk" we want to eliminate lasts. When can this "risk" be considered "off"?
            // When we find (without hitting the reader! (and the reader cannot go back)) an element without a diversion.
            // Because: Such element allows us to "postpone" the diversion decision until (at least) that element.
            // What if that element is in the last ring where no diversion is possible anymore?
            // Answer: The better: The Queue is then fully extended.
            //
            // Difference from the Lock-Free Queue: Here the reader position may be in transient state too
            // (which does not exist in the Lock-Free Queue). Yes: The possibility of hitting the reader position
            // in transient state increases the "eagerness" of the extensions.
            //
            // note: The conditions (FIRST_ARRAY_SIZE << rix) != ix must now be always fulfilled, because going
            // over diversions forward never goes beyond the end of the ring. However we keep the conditions here
            // for assertion reasons (in the real code they are not needed).

            do
            :: (((FIRST_ARRAY_SIZE << testNextWriterRix) != testNextWriterIx)
             && ((oppositeRix == testNextWriterRix) && (oppositeIx == testNextWriterIx))) ->
            {
                // if we hit the reader: we try to extend
                //
                // note: Here it is not necessary to test the rounds, because here we are helping to finish an Enqueue operation:
                // The element (high) CAS succeeds (and so our result divertToRixNew becomes effective) only if the writer
                // has not yet moved from the place where the Enqueue operation started. But in such case the reader can only be
                // in the previous round strictly ahead of the writer (because the same place would either have meant "Queue is full"
                // or have triggered the Enqueue to first help the reader move to its stationary state),
                // or in the same round behind the writer or on the same place (because a reader that would advance "beyond"
                // would have triggered the Dequeue to first help us (the writer) move to the stationary state).

                printf("TID %d helpLinearizeTid %d elementLowTid %d extend Queue checking have hit the reader (%d)\n", ownTid, helpLinearizeTid, elementLowTid, testNextWriterRix);
                goto help_finish_check_if_new_diversion_yes;
            }
            :: (((FIRST_ARRAY_SIZE << testNextWriterRix) != testNextWriterIx)
             && ((oppositeRix != testNextWriterRix) || (oppositeIx != testNextWriterIx))
             && (0 == rings[testNextWriterRix].elements[testNextWriterIx].highDivertToRix)) ->
            {
                // we have reached another place without a diversion (and without the reader):
                // the risk can now be "switched off" (see above), so stop

                printf("TID %d helpLinearizeTid %d elementLowTid %d extend Queue checking risk off (%d)\n", ownTid, helpLinearizeTid, elementLowTid, testNextWriterRix);
                goto help_finish_cas_element_high;
            }
            :: (((FIRST_ARRAY_SIZE << testNextWriterRix) != testNextWriterIx)
             && ((oppositeRix != testNextWriterRix) || (oppositeIx != testNextWriterIx))
             && (0 != rings[testNextWriterRix].elements[testNextWriterIx].highDivertToRix)) ->
            {
                // we have reached a place with a diversion forward (but without the reader):
                // we have to continue to there
                //
                // is it possible that the divertToRix is already there but the new ring is not yet allocated
                // (i.e. the extension helping is not yet finished)? Answer yes: this is possible.
                // But if this happens, then there must have been a successful element (high) CAS on a different *) element than on our
                // copy of the writer in the stationary state, which means that there must also have been a successful element (high) CAS
                // on our copy of the writer position before, so our element (high) CAS will fail, so we can stop here.
                // (actually we must stop here to avoid dereferencing a null pointer.)
                //
                // *) (in extreme case of rings[0][0] also possibly the same element)
                //
                // The reading of the element's divertToRix for going over the diversion(s) forward
                // and the testing of ringsAllocMemory is the reason why this is modeled as a separate atomic step.
                // Note that this going forward and testing occurs in the same temporal order as the items
                // are laid, so no interleaves can affect the result more than the temporal position
                // of this whole atomic step as such: no need for even more TLWACCHes.

                testNextWriterRix = rings[testNextWriterRix].elements[testNextWriterIx].highDivertToRix;
                testNextWriterIx = 0;

                if
                :: (0 == ringsAllocMemory[testNextWriterRix]) ->
                {
                    printf("TID %d helpLinearizeTid %d elementLowTid %d extend Queue checking stopped at not-yet helped divertToRix (%d)\n", ownTid, helpLinearizeTid, elementLowTid, testNextWriterRix);
                    elementCasAssert = false;  // assert the "element CAS will fail" statement above
                    goto help_finish_cas_element_high;
                }
                :: else ->
                {
                    printf("TID %d helpLinearizeTid %d elementLowTid %d extend Queue checking continues with divertToRix (%d)\n", ownTid, helpLinearizeTid, elementLowTid, testNextWriterRix);
                }
                fi
            }
            :: else -> assert(false);  // the conditions above combine to no logical gaps and no logical overlaps
            od
        }
    }
    :: else ->
    {
        goto help_finish_cas_element_high;
    }
    fi

help_finish_check_if_new_diversion_yes :

    /*TLWACCH*/

    // try to determine divertToRixNew by searching the rings array for the lowest not-yet-allocated ring
    atomic
    {
        // the search is bottom-up and the allocations are also bottom-up, so no interleaves within the search
        // can affect the result more than the temporal position of this whole atomic step as such: no need for several TLWACCHes
        //
        // performance: this is a linear search over a very short rings array that is frequently accessed (i.e. is in cache)
        // done only when the Queue considers extending (which might however be frequent in a nearly-full state).
        // Alternative: maintain a separate variable ringsMaxIndex (at the cost of extra CAS).
        //
        // Theoretically this whole atomic step could be conditional on "Queue not yet fully extended",
        // which translates to (0 == ringsAllocMemory[CNT_ALLOWED_EXTENSIONS]), but this would add
        // an extra memory read in the mainstream case.

        // search for the lowest not-yet-allocated ring
        assert(0 == divertToRixNew);  // follows from above
        do
        :: (0 == ringsAllocMemory[divertToRixNew]) ->
        {
            break;  // we have found the lowest not-yet allocated ring at divertToRixNew
        }
        :: ((divertToRixNew == CNT_ALLOWED_EXTENSIONS) && (0 != ringsAllocMemory[divertToRixNew])) ->
        {
            divertToRixNew = 0;  // Queue is already fully extended
            break;
        }
        :: ((divertToRixNew < CNT_ALLOWED_EXTENSIONS) && (0 != ringsAllocMemory[divertToRixNew])) ->
        {
            divertToRixNew ++;
        }
        :: else -> assert(false);  // the conditions above combine to no logical gaps and no logical overlaps
        od
        printf("TID %d helpLinearizeTid %d elementLowTid %d divertToRixNew %d\n", ownTid, helpLinearizeTid, elementLowTid, divertToRixNew);
    }

help_finish_cas_element_high :

    /*TLWACCH*/

    // try the element (high) CAS (this may include implantation of a new diversion)
    atomic
    {
        assert(elementLowEnqueue);  // follows from above
        assert((effectiveRound == (1 + elementHighRound)) || (false == elementHighDirty));  // follows from above
        assert((0 == divertToRixNew) || (0 == elementHighDivertToRix));  // both never non-zero, follows from above

        if
        :: ((elementHighValue       == rings[effectiveRix].elements[effectiveIx].highValue)
         && (elementHighRound       == rings[effectiveRix].elements[effectiveIx].highRound)
         && (elementHighDirty       == rings[effectiveRix].elements[effectiveIx].highDirty)
         && (elementHighDivertToRix == rings[effectiveRix].elements[effectiveIx].highDivertToRix)) ->
        {
            printf("TID %d helpLinearizeTid %d elementLowTid %d element (high) CAS succeeded in rings[%d][%d]\n", ownTid, helpLinearizeTid, elementLowTid, effectiveRix, effectiveIx);
            assert(elementCasAssert);

            sawElementLowTidAlive = true;

            rings[effectiveRix].elements[effectiveIx].highValue       = stateValue;
            rings[effectiveRix].elements[effectiveIx].highRound       = effectiveRound;
            rings[effectiveRix].elements[effectiveIx].highDirty       = true;
            rings[effectiveRix].elements[effectiveIx].highDivertToRix = (divertToRixNew | elementHighDivertToRix);  // both never non-zero

            elementHighValue       = stateValue;      // (not needed later, just for consistency)
            elementHighRound       = effectiveRound;  // (not needed later, just for consistency)
            elementHighDirty       = true;            // (not needed later, just for consistency)
            elementHighDivertToRix = (divertToRixNew | elementHighDivertToRix);
        }
        :: else ->  // the element (high) CAS failed, get the current element value (this still goes atomically with CMPXCHG16B)
        {
            printf("TID %d helpLinearizeTid %d elementLowTid %d element (high) CAS failed in rings[%d][%d]\n", ownTid, helpLinearizeTid, elementLowTid, effectiveRix, effectiveIx);

            // getting the new elementHighDivertToRix is necessary because the thread that did the successful element (high) CAS might
            // have done a different decision about the diversion and we now need to know this decision

            elementHighValue       = rings[effectiveRix].elements[effectiveIx].highValue;  // (not needed later, just for consistency)
            elementHighRound       = rings[effectiveRix].elements[effectiveIx].highRound;  // (not needed later, just for consistency)
            elementHighDirty       = rings[effectiveRix].elements[effectiveIx].highDirty;  // (not needed later, just for consistency)
            elementHighDivertToRix = rings[effectiveRix].elements[effectiveIx].highDivertToRix;

            assert(true == elementHighDirty);
            assert(effectiveRound <= elementHighRound);  // the round from the successful CAS can be only equal or higher than "ours"
        }
        fi
    }

help_finish_cas_state :

    /*TLWACCH*/

    atomic
    {
        assert(elementLowPhase == statePhase);  // follows from above
        assert(elementLowEnqueue == stateEnqueue);
        assert(false == stateFullOrEmpty);
        assert(true == statePending);
        assert(true == stateInProgress);

        if
        :: (elementLowEnqueue) ->
        {
            // 8-byte CAS to only switch-off the pending flag
            // Remark: The operation is uniquely identified by the phase number alone, so no comparison of the value is needed.
            // Further, after this step the value is not needed, so no need to retrieve it back when the CAS fails.
            // Therefore, the "cheaper" CMPXCHG8B is sufficient here.
            if
            :: ((statePhase       == state[elementLowTid].phase)
             && (stateEnqueue     == state[elementLowTid].enqueue)
             && (stateFullOrEmpty == state[elementLowTid].fullOrEmpty)
             && (statePending     == state[elementLowTid].pending)
             && (stateInProgress  == state[elementLowTid].inProgress)) ->
            {
                printf("TID %d helpLinearizeTid %d elementLowTid %d (enqueue): state CAS succeeded\n", ownTid, helpLinearizeTid, elementLowTid);

                assert(stateValue == state[elementLowTid].value);  // value must be equal (because the phase number alone is a unique identifier)

                sawElementLowTidAlive = true;

                state[elementLowTid].pending = false;
                statePending = false;
            }
            :: else ->  // the state CAS failed, get the current element value (this still goes atomically with CMPXCHG8B)
            {
                assert((false == state[elementLowTid].pending) || (statePhase < state[elementLowTid].phase));

                printf("TID %d helpLinearizeTid %d elementLowTid %d (enqueue): state CAS failed\n", ownTid, helpLinearizeTid, elementLowTid);

                stateValue       = -2;  // in the model only: assign a value that would throw the FIFO assert if indeed used
                statePhase       = state[elementLowTid].phase;
                stateEnqueue     = state[elementLowTid].enqueue;
                stateFullOrEmpty = state[elementLowTid].fullOrEmpty;
                statePending     = state[elementLowTid].pending;
                stateInProgress  = state[elementLowTid].inProgress;
            }
            fi
        }
        :: else ->  // Dequeue
        {
            // 16-byte CAS to write the dequeued value and switch-off the pending flag

            if
            :: ((stateValue       == state[elementLowTid].value)
             && (statePhase       == state[elementLowTid].phase)
             && (stateEnqueue     == state[elementLowTid].enqueue)
             && (stateFullOrEmpty == state[elementLowTid].fullOrEmpty)
             && (statePending     == state[elementLowTid].pending)
             && (stateInProgress  == state[elementLowTid].inProgress)) ->
            {
                printf("TID %d helpLinearizeTid %d elementLowTid %d (dequeue): state CAS succeeded\n", ownTid, helpLinearizeTid, elementLowTid);

                // verify (again) the correct FIFO order via array linearizationOrder
                assert(linearizationOrder[cntDequeued - 1] == elementHighValue);

                sawElementLowTidAlive = true;

                state[elementLowTid].value = elementHighValue;
                state[elementLowTid].pending = false;

                stateValue = elementHighValue;
                statePending = false;
            }
            :: else ->  // the state CAS failed, get the current element value (this still goes atomically with CMPXCHG16B)
            {
                assert((false == state[elementLowTid].pending) || (statePhase < state[elementLowTid].phase));

                printf("TID %d helpLinearizeTid %d elementLowTid %d (dequeue): state CAS failed\n", ownTid, helpLinearizeTid, elementLowTid);

                stateValue       = state[elementLowTid].value;
                statePhase       = state[elementLowTid].phase;
                stateEnqueue     = state[elementLowTid].enqueue;
                stateFullOrEmpty = state[elementLowTid].fullOrEmpty;
                statePending     = state[elementLowTid].pending;
                stateInProgress  = state[elementLowTid].inProgress;
            }
            fi
        }
        fi
    }

help_finish_extension :

    /*TLWACCH*/

    // Extension helping
    //
    // Setting ringsAllocMemory[elementHighDivertToRix] to nonzero is the concluding step 2 of the extension helping,
    // so once nonzero, no extension helping is needed anymore. The respective test shall be quick
    // due to the rings array presumably being in cache.
    atomic
    {
        if
        :: ((0 == elementHighDivertToRix) || (0 != ringsAllocMemory[elementHighDivertToRix])) ->
        {
            goto help_finish_cas_effective_position;
        }
        :: else;
        fi
    }

help_finish_extension_part_1 :

    /*TLWACCH*/

    // if the extension is not yet finished, finish it - part 1
    d_step
    {
        // try to CAS the diversion into the diversions array
        // (remark: if the diversion is at (0,0), then this CAS may succeed several times (not an issue))
        if
        :: ((0 == diversions[elementHighDivertToRix - 1].rix)
         && (0 == diversions[elementHighDivertToRix - 1].ix)) ->
        {
            // impossible for the position to be written to already exist in the diversions array, but better check ...
            byte tmpRix;
            for (tmpRix : 1 .. CNT_ALLOWED_EXTENSIONS)
            {
                assert((diversions[tmpRix - 1].rix != effectiveRix)
                    || (diversions[tmpRix - 1].ix  != effectiveIx)
                    || ((0 == effectiveRix) && (0 == effectiveIx)));
            }

            // CAS write part
            printf("TID %d helpLinearizeTid %d elementLowTid %d filled diversions[%d]\n", ownTid, helpLinearizeTid, elementLowTid, elementHighDivertToRix - 1);
            diversions[elementHighDivertToRix - 1].rix = effectiveRix;
            diversions[elementHighDivertToRix - 1].ix  = effectiveIx;
        }
        :: else ->
        {
            printf("TID %d helpLinearizeTid %d elementLowTid %d failed to fill diversions[%d]\n", ownTid, helpLinearizeTid, elementLowTid, elementHighDivertToRix - 1);

            // the CAS could have failed only due to the desired value already there, but better check ...
            assert((diversions[elementHighDivertToRix - 1].rix == effectiveRix)
                && (diversions[elementHighDivertToRix - 1].ix  == effectiveIx));
        }
        fi
    }

help_finish_extension_part_2 :

    /*TLWACCH*/

    // if the extension is not yet finished, finish it - part 2
    d_step
    {
        // in the real program: test here once again that the new ring is not yet allocated
        // to reduce unnecessary allocations as much as possible

        printf("TID %d helpLinearizeTid %d elementLowTid %d allocated memory for rings[%d]\n", ownTid, helpLinearizeTid, elementLowTid, elementHighDivertToRix);
        // in the real program: allocate the memory for the new ring ((FIRST_ARRAY_SIZE << elementHighDivertToRix) elements)

        // try to CAS the new ring into the rings array
        if
        :: (0 == ringsAllocMemory[elementHighDivertToRix]) ->
        {
            // impossible for that exact memory allocation to already exist, but better check ...
            byte tmpRix;
            for (tmpRix : 0 .. CNT_ALLOWED_EXTENSIONS)
            {
                assert(ringsAllocMemory[tmpRix] != (FIRST_ARRAY_SIZE << elementHighDivertToRix));
            }

            // CAS write part
            printf("TID %d helpLinearizeTid %d elementLowTid %d used allocated memory for rings[%d]\n", ownTid, helpLinearizeTid, elementLowTid, elementHighDivertToRix);
            ringsAllocMemory[elementHighDivertToRix] = (FIRST_ARRAY_SIZE << elementHighDivertToRix);
        }
        :: else ->
        {
            printf("TID %d helpLinearizeTid %d elementLowTid %d threw away allocated memory for rings[%d]\n", ownTid, helpLinearizeTid, elementLowTid, elementHighDivertToRix);
            // in the real program: we have to de-allocate the memory again (pity)

            // the CAS could have failed only due to the desired memory allocation already there, but better check ...
            assert(ringsAllocMemory[elementHighDivertToRix] == (FIRST_ARRAY_SIZE << elementHighDivertToRix));
        }
        fi
    }

help_finish_cas_effective_position :

    /*TLWACCH*/

    // now go forward with the writer/reader position and try to CAS it
    atomic
    {
        if
        :: (0 != elementHighDivertToRix) ->  // if there is a diversion to be followed forward
        {
            effectiveRix = elementHighDivertToRix;
            effectiveIx  = 0;
        }
        :: else ->  // otherwise
        {
            effectiveIx ++;  // prospective move up

            do
            :: ((FIRST_ARRAY_SIZE << effectiveRix) == effectiveIx) ->  // if beyond the end of the ring
            {
                if
                :: (0 == effectiveRix) ->  // the return from the end of rings[0] to rings[0][0] is implicit
                {
                    effectiveRound ++;  // we are passing rings[0][0], so increment round
                    effectiveRix = 0;  // move to rings[0][0]
                    effectiveIx  = 0;
                    break;
                }
                :: else ->  // follow the diversion back (the diversions entries must exist, no need for extra TLWACCHes)
                {
                    byte tmpRix = effectiveRix;
                    effectiveRix = diversions[tmpRix - 1].rix;
                    effectiveIx  = (1 + diversions[tmpRix - 1].ix);
                }
                fi
            }
            :: else -> break;
            od
        }
        fi

        // the following is just an assert (so no extra TLWACCH):
        //
        // the step help_finish_check_if_new_diversion is there to eliminate the risk that the Queue gets stuck
        // due to the writer hitting the reader (in the previous round) "from behind" and it has not seen such risk
        // (otherwise it would have eliminated it by creating a new diversion and going to it
        // (except when the Queue was already fully extended, of course))
        //
        // so now: as the reader cannot move back, it is impossible that we hit him, but better check ...
        //
        // note: here we have to test against the readerPosition in memory and not against our copy,
        // because our copy could have indicated an extension, so we would have prepared the extension
        // but then have lost the element (high) CAS to another writer who saw the reader in a later position
        // and has hence not prepared the extension, so we would then (correctly) have gone forward
        // according to the winning writer's decision (i.e. without a diversion), which would make us hit
        // our copy of readerPosition but of course not the "real" readerPosition in memory
        if
        :: ((elementLowEnqueue)
         && ((1 + readerPositionRound) == effectiveRound)
         && (readerPositionRix == effectiveRix)
         && (readerPositionIx == effectiveIx)
         && (0 == ringsAllocMemory[CNT_ALLOWED_EXTENSIONS])  // Queue is not yet fully extended
        ) -> {
            assert(false);
        }
        :: else;
        fi

        assert(effectiveIx < (FIRST_ARRAY_SIZE << effectiveRix));

        if
        :: (elementLowEnqueue) ->
        {
            // CAS the writer position
            if
            :: ((origEffectiveRound == writerPositionRound)
             && (origEffectiveRix   == writerPositionRix)
             && (origEffectiveIx    == writerPositionIx)) ->
            {
                printf("TID %d helpLinearizeTid %d elementLowTid %d writerPosition CAS Success (%d,%d,%d)\n", ownTid, helpLinearizeTid, elementLowTid, effectiveRound, effectiveRix, effectiveIx);

                writerPositionRound = effectiveRound;
                writerPositionRix   = effectiveRix;
                writerPositionIx    = effectiveIx;

                // check if our diversion info was right (no extra TLWACCH: just an assert)
                assert(elementHighDivertToRix == rings[origEffectiveRix].elements[origEffectiveIx].highDivertToRix);
            }
            :: else ->  // the writer position CAS failed: get the current value (this still goes atomically with CMPXCHG16B)
            {
                printf("TID %d helpLinearizeTid %d elementLowTid %d writerPosition CAS failed (%d,%d,%d)\n", ownTid, helpLinearizeTid, elementLowTid, effectiveRound, effectiveRix, effectiveIx);

                effectiveRound = writerPositionRound;
                effectiveRix   = writerPositionRix;
                effectiveIx    = writerPositionIx;
            }
            fi

            origEffectiveRound = effectiveRound;
            origEffectiveRix   = effectiveRix;
            origEffectiveIx    = effectiveIx;

            // Thanks to the writer position CAS we now have a current copy of the writer position and can omit its re-reading.

            enqueueEffectiveSkip = true;
        }
        :: else ->  // Dequeue
        {
            // now go forward with the reader position and try to CAS it
            //
            // Question about if "our" diversion info (elementHighDivertToRix) is right:
            // Yes, because a potential new diversion is implanted where the writer succeeds with its element (high) CAS and:
            //
            // A) In the "empty case" there is no hazard because a reader about to advance beyond the writer
            //    would have triggered the Dequeue to first help the writer move to its stationary state,
            //    i.e. finish an eventual extension of the Queue.
            //
            // B) In the "full case" the writer cares about creating new diversions if it sees us "ahead", so the hazardous place
            //    is "behind us". Eventual readers with outdated reader position (that may see the hazardous place) will
            //    fail on this reader position CAS.

            // CAS the reader position
            if
            :: ((origEffectiveRound == readerPositionRound)
             && (origEffectiveRix   == readerPositionRix)
             && (origEffectiveIx    == readerPositionIx)) ->
            {
                printf("TID %d helpLinearizeTid %d elementLowTid %d readerPosition CAS Success (%d,%d,%d)\n", ownTid, helpLinearizeTid, elementLowTid, effectiveRound, effectiveRix, effectiveIx);

                readerPositionRound = effectiveRound;
                readerPositionRix   = effectiveRix;
                readerPositionIx    = effectiveIx;

                // check if our diversion info was right (no extra TLWACCH: just an assert)
                assert(elementHighDivertToRix == rings[origEffectiveRix].elements[origEffectiveIx].highDivertToRix);
            }
            :: else ->  // the reader position CAS failed: get the current value (this still goes atomically with CMPXCHG16B)
            {
                printf("TID %d helpLinearizeTid %d elementLowTid %d readerPosition CAS failed (%d,%d,%d)\n", ownTid, helpLinearizeTid, elementLowTid, effectiveRound, effectiveRix, effectiveIx);

                effectiveRound = readerPositionRound;
                effectiveRix   = readerPositionRix;
                effectiveIx    = readerPositionIx;
            }
            fi

            origEffectiveRound = effectiveRound;
            origEffectiveRix   = effectiveRix;
            origEffectiveIx    = effectiveIx;

            // Thanks to the reader position CAS we now have a current copy of the reader position and can omit its re-reading.

            dequeueEffectiveSkip = true;
        }
        fi

        // end of the helping to finish

        // The state record of elementLowTid must now be not pending anymore (either due to "us" or due to other helpers)
        // or it may contain already a newer operation:
        assert((false == state[elementLowTid].pending) || (elementLowPhase < state[elementLowTid].phase));
        assert((false == statePending) || (elementLowPhase < statePhase));

        if
        :: (sawElementLowTidAlive) ->
        {
            // If we saw elementLowPhase alive (i.e. after having taken "our" phase), we can make a stronger assert:
            assert((false == state[elementLowTid].pending) || (ownPhase < state[elementLowTid].phase));
            assert((false == statePending) || (ownPhase < statePhase));

            if
            :: (helpLinearizeTid == elementLowTid) ->  // elementLowTid was our linearization helpee
            {
                // switch to next linearization helpee will occur in test_helpee_state (see assert above)
                goto test_helpee_state;
            }
            :: else;
            fi

            // Remark: If we have not seen elementLowPhase alive, then the stronger assert above might not hold:
            // Imagine Thread A linearized elementLowPhase and helped finish it up to (and including) the state array CAS,
            // but the moving the effective position forward is yet outstanding.
            // Thread B (the owner of elementLowPhase) saw its operation in the state array as "done" so it returned
            // and entered back again with a new operation, drew a new state number and wrote it into the state array.
            // Thread C ("us") entered, drew "our" phase number, saw the unfinished effective position (i.e. the transient state),
            // helped to finish it and landed here with own phase that is higher!
        }
        :: else;
        fi

        goto read_helpee_state;  // otherwise re-read state
    }

    //  _  _ ____ _    ___     ____ _  _ _    _      ____ ____    ____ _  _ ___  ___ _   _
    //  |__| |___ |    |__]    |___ |  | |    |      |  | |__/    |___ |\/| |__]  |   \_/
    //  |  | |___ |___ |       |    |__| |___ |___   |__| |  \    |___ |  | |     |    |

help_full_empty_re_read_state :

    /*TLWACCH*/

    // jump into here if the element (low part) contains the linearized fullOrEmpty flag to be finished on an operation
    // that is different from the operation that was intended for linearization (i.e. re-reading from state (8 bytes only) is needed)

    atomic
    {
        assert(statePhase != elementLowPhase);  // follows from above (new statePhase will be read below)

        stateValue       = -2;  // in the model only: assign a value that would throw the FIFO assert if indeed used
        statePhase       = state[elementLowTid].phase;
        stateEnqueue     = state[elementLowTid].enqueue;
        stateFullOrEmpty = state[elementLowTid].fullOrEmpty;
        statePending     = state[elementLowTid].pending;
        stateInProgress  = state[elementLowTid].inProgress;

        printf("TID %d helpLinearizeTid %d elementLowTid %d finish full/empty: re-read state\n", ownTid, helpLinearizeTid, elementLowTid);

        assert(elementLowPhase <= statePhase);

        if
        :: (elementLowPhase != statePhase) ->
        {
            printf("TID %d helpLinearizeTid %d elementLowTid %d finish full/empty: state record contains already a new operation\n", ownTid, helpLinearizeTid, elementLowTid);
            goto help_full_empty_cas_element_low;
        }
        :: else;
        fi

        assert(elementLowEnqueue == stateEnqueue);

        if
        :: (false == statePending) ->
        {
            printf("TID %d helpLinearizeTid %d elementLowTid %d finish full/empty: operation not pending anymore\n", ownTid, helpLinearizeTid, elementLowTid);
            goto help_full_empty_cas_element_low;
        }
        :: else;
        fi
    }

help_full_empty_cas_state :

    /*TLWACCH*/

    // CAS the low 8 bytes of the state record to set fullOrEmpty and switch-off pending

    // Remark: The operation is uniquely identified by the phase number alone, so no comparison of the value is needed.
    // Further, after this step the value is not needed, so no need to retrieve it back when the CAS fails.
    // Therefore, the "cheaper" CMPXCHG8B is sufficient here.

    // jump into here if the element (low part) contains the linearized fullOrEmpty flag to be finished
    // on the operation that was intended for linearization (i.e. no re-reading from state is needed)

    atomic
    {
        assert(elementLowPhase == statePhase);  // follows from above
        assert(elementLowEnqueue == stateEnqueue);
        assert(false == stateFullOrEmpty);
        assert(true == statePending);
        assert(true == stateInProgress);

        if
        :: ((statePhase       == state[elementLowTid].phase)
         && (stateEnqueue     == state[elementLowTid].enqueue)
         && (stateFullOrEmpty == state[elementLowTid].fullOrEmpty)
         && (statePending     == state[elementLowTid].pending)
         && (stateInProgress  == state[elementLowTid].inProgress)) ->
        {
            printf("TID %d helpLinearizeTid %d elementLowTid %d finish full/empty: state CAS succeeded\n", ownTid, helpLinearizeTid, elementLowTid);

            // value must be equal (because the phase number alone is a unique identifier)
            // (caution: stateValue might have been assigned -2 in help_full_empty_re_read_state)
            assert((-2 == stateValue) || (stateValue == state[elementLowTid].value));

            sawElementLowTidAlive = true;

            state[elementLowTid].fullOrEmpty = true;
            state[elementLowTid].pending = false;

            stateFullOrEmpty = true;
            statePending = false;
        }
        :: else ->  // the state CAS failed
        {
            assert((false == state[elementLowTid].pending) || (statePhase < state[elementLowTid].phase));

            printf("TID %d helpLinearizeTid %d elementLowTid %d finish full/empty: state CAS failed\n", ownTid, helpLinearizeTid, elementLowTid);

            stateValue       = -2;  // in the model only: assign a value that would throw the FIFO assert if indeed used
            statePhase       = state[elementLowTid].phase;
            stateEnqueue     = state[elementLowTid].enqueue;
            stateFullOrEmpty = state[elementLowTid].fullOrEmpty;
            statePending     = state[elementLowTid].pending;
            stateInProgress  = state[elementLowTid].inProgress;
        }
        fi
    }

help_full_empty_cas_element_low :

    /*TLWACCH*/

    // 16-byte CAS on element (low part) to set lowFullEmptyFinished

    atomic
    {
        assert(true == elementLowFullEmpty);

        if
        :: ((elementLowPhase             == rings[effectiveRix].elements[effectiveIx].lowPhase)
         && (elementLowEnqueue           == rings[effectiveRix].elements[effectiveIx].lowEnqueue)
         && (elementLowFullEmpty         == rings[effectiveRix].elements[effectiveIx].lowFullEmpty)
         && (elementLowFullEmptyFinished == rings[effectiveRix].elements[effectiveIx].lowFullEmptyFinished)
         && (elementLowRound             == rings[effectiveRix].elements[effectiveIx].lowRound)
         && (elementLowDirty             == rings[effectiveRix].elements[effectiveIx].lowDirty)
         && (elementLowTid               == rings[effectiveRix].elements[effectiveIx].lowTid)) ->
        {
            printf("TID %d helpLinearizeTid %d elementLowTid %d finish full/empty: element (low) CAS succeeded in rings[%d][%d]\n", ownTid, helpLinearizeTid, elementLowTid, effectiveRix, effectiveIx);

            // Why the lowFullEmptyFinished flag?
            // Assume we wouldn't have this flag and would only clear the lowFullEmpty flag here.
            // In the case of Dequeue (i.e. the empty result), the situation would then be undistinguishable from a regular Dequeue,
            // so other threads would try to help it including shifting the reader position forward (which would be wrong).

            rings[effectiveRix].elements[effectiveIx].lowFullEmptyFinished = true;
        }
        :: else ->
        {
            printf("TID %d helpLinearizeTid %d elementLowTid %d finish full/empty: element (low) CAS failed in rings[%d][%d]\n", ownTid, helpLinearizeTid, elementLowTid, effectiveRix, effectiveIx);
        }
        fi

        // end of the helping to finish full/empty

        // The state record of elementLowTid must now be not pending anymore (either due to "us" or due to other helpers)
        // or it may contain already a newer operation:
        assert((false == state[elementLowTid].pending) || (elementLowPhase < state[elementLowTid].phase));
        assert((false == statePending) || (elementLowPhase < statePhase));

        if
        :: (sawElementLowTidAlive) ->
        {
            // If we saw elementLowPhase alive (i.e. after having taken "our" phase), we can make a stronger assert:
            assert((false == state[elementLowTid].pending) || (ownPhase < state[elementLowTid].phase));
            assert((false == statePending) || (ownPhase < statePhase));

            if
            :: (helpLinearizeTid == elementLowTid) ->  // elementLowTid was our linearization helpee
            {
                // switch to next linearization helpee will occur in test_helpee_state (see assert above)
                goto test_helpee_state;
            }
            :: else;
            fi

            // Remark: If we have not seen elementLowPhase alive, then the stronger assert above might not hold:
            // Imagine Thread A linearized full/empty for elementLowPhase and helped finish it up to (and including)
            // the state array CAS, but the setting of lowFullEmptyFinished in the element (low) is yet outstanding.
            // Thread B (the owner of elementLowPhase) saw its operation in the state array as "done" so it returned
            // and entered back again with a new operation, drew a new state number and wrote it into the state array.
            // Thread C ("us") entered, drew "our" phase number, saw the unfinished full/empty helping,
            // helped to finish it and landed here with own phase that is higher!
        }
        :: else;
        fi

        goto read_helpee_state;  // otherwise re-read state
    }

thread_end :

}

/*********************************************
 init process
 *********************************************/
init
{
    pid pids[3];
    short idx;

    // initialization of the Queue
    ringsAllocMemory[0] = FIRST_ARRAY_SIZE;

    // prefill scenario (enqueues/dequeues one after the other)
    for (idx: 0 .. PREFILL_STEPS - 1)
    {
        // start process
        if
        :: (1 == prefill[idx]) ->
        {
            pids[0] = run thread(0, true, false);
            printf("init: pre-fill enqueue process %d\n", pids[0]);
        }
        :: else ->
        {
            pids[0] = run thread(0, false, true);
            printf("init: pre-fill dequeue process %d\n", pids[0]);
        }
        fi

        // join process
        (_nr_pr <= pids[0]);
        printf("init: joined pre-fill process %d\n", pids[0]);
    }

    prefillCntEnqueued     = cntEnqueued;
    prefillCntEnqueueFull  = cntEnqueueFull;
    prefillCntDequeued     = cntDequeued;
    prefillCntDequeueEmpty = cntDequeueEmpty;

    // start all writer + reader processes concurrently
    atomic
    {
        pids[0] = run thread(0, false, false);
        pids[1] = run thread(1, false, false);
        pids[2] = run thread(2, false, false);
        printf("init: initialized all processes\n");
    }

    // join the concurrent processes
    (_nr_pr <= pids[2]);
    printf("init: joined process %d\n", pids[2]);
    (_nr_pr <= pids[1]);
    printf("init: joined process %d\n", pids[1]);
    (_nr_pr <= pids[0]);
    printf("init: joined process %d\n", pids[0]);

    // balance of enqueues
    assert(ENQUEUES == (cntEnqueued + cntEnqueueFull - (prefillCntEnqueued + prefillCntEnqueueFull)));

    // balance of dequeues
    assert(DEQUEUES == (cntDequeued + cntDequeueEmpty - (prefillCntDequeued + prefillCntDequeueEmpty)));

    // now: except when the concurrent phase resulted in an empty Queue (unlikely but possible),
    // start reader processes one-after-the-other to empty the Queue
    // and then check that the Queue is indeed empty

    short tmpCnt = cntEnqueued - cntDequeued;
    printf("init: left in the Queue %d\n", tmpCnt);

    for (idx: 0 .. (tmpCnt - 1))
    {
        // start process
        pids[0] = run thread(0, false, true);
        printf("init: clean-up dequeue process %d\n", pids[0]);

        // join process
        (_nr_pr <= pids[0]);
        printf("init: joined clean-up process %d\n", pids[0]);
    }

    // the Queue must be empty now
    assert(cntEnqueued == cntDequeued);

    // one extra dequeue to make sure that the Queue indeed reports empty
    tmpCnt = cntDequeueEmpty;

    // start process
    pids[0] = run thread(0, false, true);
    printf("init: extra dequeue process %d\n", pids[0]);

    // join process
    (_nr_pr <= pids[0]);
    printf("init: joined extra process %d\n", pids[0]);

    assert((1 + tmpCnt) == cntDequeueEmpty)
}

/*
   _    _ _  _ ____ ____ ____ _ ___  ____ ___  _ _    _ ___ _   _
   |    | |\ | |___ |__| |__/ |   /  |__| |__] | |    |  |   \_/
   |___ | | \| |___ |  | |  \ |  /__ |  | |__] | |___ |  |    |

Linearizability (mainly by Herlihy and Wing) is an important concept in proving correctness of concurrent algorithms.

In practical terms, linearizability condenses to establishing linearization points, which are indivisible points in time
at which the operations instantaneously take effect.

The idea is that by ordering the concurrently running operations by their linearization points, one obtains
a linear (i.e. sequential / single-threaded) execution history of that operations that gives the same results.

It is advantageous to prove linearizability theoretically via the linearization points,
not only because it provides insights, but also because testing it experimentally may be intractable:
Imagine a situation with 10 threads running operations on the Queue concurrently.
How big would be the set of linear / single-threaded execution histories (permutations) of these 10 operations
on the same Queue to compare any concurrent result with: 10! = 3,6 million.

The following explanations/proofs are given in Plain English without mathematical formalisms.

All operations
--------------

The linearization point of all operations is the successful 16-byte CAS on the low part of the array element.
This CAS implants the TID of the linearized operation (TID is the index into the state array that contains the OpDesc descriptors)
along with the phase number of the operation, the Enqueue/Dequeue info and the flag for an eventual full/empty result.

The low part of the array element also contains the round number and the dirty flag that have the same two functions as in the
Lock-Free Queue: prevent round-level ABA and enable all possible fill levels (ranging from all elements empty to all elements filled).

The phase number also has two functions: The first function is to control which threads (helpers) help which other
threads (helpees) to linearize: To achieve wait-freedom as in the Kogan-Petrank Queue, helpers help helpees to linearize
operations that have phase numbers less than or equal to the phase number of the operation of the helper
(the "or equal" means that the helper is allowed to help itself too, of course).
The second function of the phase number is to prevent another ABA that could occur in the passing of information
between the array elements and the state array.

The Queue has two ends: The writer position (the Queue tail) and the reader position (the Queue head).
In their stationary states, they point to the "next to write" and "next to read" elements.
After the respective linearization ("write" or "read"), the respective position becomes transient,
and this lasts until the finish helping is done (the last operation of each finish helping
is moving the respective position forwards (to the new stationary state)).

Besides the regular ("write" or "read") linearizations, the Queue must also implement the "full on Enqueue" and
"empty on Dequeue" outcomes, which are linearized into the low part of the array elements as well.
These full/empty results have their own helping to finish.

In the following we say that the respective end of the Queue (the position that is "effective" for the given operation)
is "good for linearization" if it is not transient and there is no open full/empty helping.

So now: Each thread (helper) "goes around" the state array to see if there are helpees to help (with the last
potential helpee being the helper itself). For each helpee, it sees if the respective end of the Queue is "good for linearization".
If not, the thread tries the respective helping to make it "good" again. If yes (i.e. either it was "good" or was made "good"),
the thread tries to linearize the helpee's operation and then (again) tries to help finish it.

So far the high-level description. Now to the details:

From establishing the "good for linearization" state, the thread has the local copy of the respective array element (low part).
After that the thread checks in the state array if the operation it intends to linearize is still pending.
So if now the CAS of the array element (low part) against the local copy succeeds, then there is/was a guarantee
that no operation of the same type (Enqueue/Dequeue) - and so less the intended operation - has been linearized in between.
This is an important protection against linearizing one operation multiple times.
If the CAS failed, then another thread has linearized that (or another) operation on that array element.
In any case, the "linearization decision" is now done and the thread goes on to help this "decision" finish.

Help finish a regular Enqueue:
- - - - - - - - - - - - - - - -
If the linearized operation is different from the intended operation (statePhase != elementLowPhase),
the thread re-reads the state array to obtain the info about the linearized operation.
Then the thread reads the array element (high part). The round number/dirty flag combination is the "clamp"
between the low part and the high part of the element to determine if the high part is "good to CAS".
If yes, then a diversion decision must be done. The logic (and program code) of this diversion decision
is the same as in the Lock-Free Queue. With this preparation the CAS of the high part is attempted.
If it succeeds, then the payload and the respective diversion decision is implanted.
A failure means that another thread has won the CAS (possibly with a different diversion decision).
(Side remark: Note that each finish helping step can - in an extreme case - be done by a different thread.)
The next step of the finish helping is to switch off the pending flag in the state array, again via a CAS.
Then comes the helping to finish an eventual extension operation (the logic and the program code are the same
as in the Lock-Free Queue), concluded by the CAS for the final going forward with the writer position.
The success of this last CAS (again either by "us" or by another thread) restores the "good for next linearization" state
of the writer end of the Queue.

Help finish a regular Dequeue:
- - - - - - - - - - - - - - - -
If the linearized operation is different from the intended operation (statePhase != elementLowPhase),
the thread re-reads the state array to obtain the info about the linearized operation.
Then the thread reads the array element (high part). The round number/dirty flag combination is the "clamp"
between the low part and the high part of the element to determine if the high part was "good to read".
If yes, the thread tries to write the read payload into the state array, again via a CAS
(together with switching off the pending flag there).
Then comes the helping to finish an eventual extension operation (the logic and the program code are the same
as in the Lock-Free Queue), concluded by the CAS for the final going forward with the reader position.
The success of this last CAS (again either by "us" or by another thread) restores the "good for next linearization" state
of the reader end of the Queue.

Help finish a full/empty outcome:
- - - - - - - - - - - - - - - - -
The full (on Enqueue) or empty (on Dequeue) outcome is detected from the actual contents of the low part of the element
in the "good to linearize" state of the writer position or the reader position.
The outcome is then communicated to the element (low part) CAS step via the local isNowFullOrEmpty boolean.
If that CAS succeeds, then the full/empty result is linearized into the element (lowFullEmpty flag).
(Details: the lowTid and lowPhase are set, lowEnqueue stays (fortunately) the same, lowRound + lowDirty unchanged).
The full/empty helping code then transfers the full/empty information to the state array
and then sets the lowFullEmptyFinished flag in the element, thus finishing the helping.
As with the regular Enqueues/Dequeues, other threads will help finish this full/empty handling
if they see it unfinished (and here as well each step (CAS) can be possibly done by a different thread).

*/

