# Wait-Free Multi-Array Queue

This is the "latest evolution" of the Multi-Array Queues (after the [Java Queues](https://github.com/MultiArrayQueue/MultiArrayQueue)
and the [Lock-Free Queue](https://github.com/MultiArrayQueue/LockFreeMultiArrayQueue)):
A Queue that is linearizable, lock-free, and in the steady state (i.e. no Queue extensions (anymore)) also wait-free and garbage-free.

The garbage-freedom in the steady state makes this Queue wait-free unconditionally, as no memory allocator
(that would disturb the wait-freedom) is involved in there.

This work has been inspired by the [Kogan & Petrank Queue](https://csaws.cs.technion.ac.il/~erez/Papers/wfquque-ppopp.pdf)
in the sense that the linearization operations themselves can be helped by other threads if the helpee has a phase number
lower than (or equal to) the phase number of the helper. Other actions (that do not constitute linearization points)
can be helped by other threads too. Metaphorically, the algorithms can be seen as a "big carousel" of linearization helping
and helping to finish already linearized operations.

To illustrate the principle by an extreme (but possible) execution path: A thread begins its operation by drawing a new phase number
and registering the operation in the **state** array. Immediately after that it goes asleep. In the meantime
other threads help linearize and finish the registered operations. When the bespoke thread wakes up,
it "goes round" the **state** array and finds that all operations with phase numbers up to (and including) its phase number
are already done, some eventually already replaced by new operations (with higher phase numbers).
So without having done any "real work", the thread can successfully return.

The bound on the number of execution steps depends on the number of active threads (this is inherited from the Kogan & Petrank Queue).
The program codes of this Wait-Free Queue are more complex than those of the [Lock-Free Queue](https://github.com/MultiArrayQueue/LockFreeMultiArrayQueue),
and there are also more CASes on the path, so that a lower throughput is expected - even in the uncontended case.

<img src="https://MultiArrayQueue.github.io/Diagram_WaitFreeMultiArrayQueue.png" height="600">

## New Interactive Simulator of the Wait-Free Queue

[Get acquainted here](https://MultiArrayQueue.github.io/Simulator_WaitFreeMultiArrayQueue.html)

## Implementation

In short: There are currently **two implementations** aligned with each other: a Spin model and the JavaScript Simulator.
No real (i.e. non-model) implementation exists (yet).

In long: The algorithms have first been designed and verified as a model for the [Spin model checker](https://spinroot.com)
(for computer-aided simulations and exhaustive verifications). The Spin model file is the primary source of information
and comments on the algorithms as such.

After that, the [JavaScript Simulator](https://MultiArrayQueue.github.io/Simulator_WaitFreeMultiArrayQueue.html)
has been developed (for teaching and visual/manual simulations and verifications).

For a future "real" implementation, similar choices exist as for the
[Lock-Free Queue](https://github.com/MultiArrayQueue/LockFreeMultiArrayQueue),
with x86-64 assembly combined with C++ presumably being the most attractive option.

## More details

The Wait-Free Multi-Array Queue is a linearizable multiple-writer multiple-reader lock-free FIFO Queue
that is in the steady state (i.e. no Queue extensions (anymore)) also wait-free and garbage-free.

The extension operations, however, involve the memory allocator which (most probably) is not wait-free.
Further, more than one thread can consider extending the Queue.
Each of these competing threads then prepares (allocates) memory for the new ring and tries to CAS it into the **rings** array.
The memory of the winning thread goes into use, but the losing threads have to free the allocated memory again.
In other words: A strict garbage-freedom has to be sacrificed in this case (in the sense that superfluous calloc-free pairs may occur).

The Wait-Free Queue builds on top of the [Lock-Free Queue](https://github.com/MultiArrayQueue/LockFreeMultiArrayQueue)
with this main difference:

One array element consists of two halves, each 128-bit wide.

The "high half" carries the payload and metadata as in the [Lock-Free Queue](https://github.com/MultiArrayQueue/LockFreeMultiArrayQueue).

The "low half" carries the Thread-ID (index into the **state** array) and the phase number of the operation
that operates on that array element. This information is necessary for the finishing steps that can be helped
by different threads (in an extreme case, the linearization and each helping step can be done by a different thread).

It is actually the successful 128-bit CAS (CMPXCHG16B) into the "low half" that is the linearization operation.

The finishing steps for Enqueue are (each being a CAS as well):

* transfer of the payload from the **state** array into the "high half" of the array element
* switch off the pending flag in the **state** array
* move the writer position forward

The finishing steps for Dequeue are (each being a CAS too):

* transfer of the payload from the "high half" of the array element into the **state** array (together with switching off the pending flag there)
* move the reader position forward

From the above follows that the Wait-Free Queue has double memory consumption compared with the
[Lock-Free Queue](https://github.com/MultiArrayQueue/LockFreeMultiArrayQueue),
which means quadruple memory consumption compared with the original
[Java Queues](https://github.com/MultiArrayQueue/MultiArrayQueue).

## Development status

 * Currently (2026), this code is only for academic interest, not for production use.
 * Reviews, tests and comments are welcome.
 * Should you have found a concurrency counterexample, please attach to your ticket your Spin input + trail file
   or the trail from the JavaScript Simulator that leads to the issue.
   *As with other similar algorithms, an eventual counterexample could be either fixable or unfixable
   (in which case the whole algorithm would have to be discarded).*
 * Do not send me Pull Requests - the code is small, so I want to maintain it single-handedly.

## License

MIT License

