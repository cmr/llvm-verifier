% **Generating Formal Models with the LLVM Symbolic Simulator**
% Galois, Inc. | 421 SW 6th Avenue, Suite 300 | Portland, OR 97204
% \includegraphics[height=1in]{images/Galois_logo_blue_box.pdf}

Introduction
============

This document provides a step-by-step guide to using the command-line
version of Galois' LLVM Symbolic Simulator, `lss`, to perform rigorous
mathematical analysis of LLVM programs. To illustrate its use, we
describe how to formally prove that an LLVM implementation of the AES
block cipher algorithm is functionally equivalent to a reference
specification. The ability to perform this sort of proof brings
benefits such as allowing programmers to experiment with efficient,
customized implementations of an algorithm while retaining confidence
that the changes do not affect the overall functionality.

We assume knowledge of C, a basic understanding of LLVM and a passing
familiarity with cryptography. However, we do not assume familiarity
with symbolic simulation, formal modeling, or theorem proving.

We assume that the user has installed the LLVM 3.0 or 3.1 toolchain
^[Available from <http://llvm.org/releases>]. Additionally,
installation of the Cryptol tool set [^cryptol] and the ABC logic
synthesis system from UC Berkeley [^abc] is necessary before
completing the equivalence checking portion of the tutorial.
Installation and configuration of those tools is outside the scope of
this tutorial.

In the examples of interaction with the simulator and other tools,
lines beginning with a hash mark (`#`) or short text followed by an
angle bracket (such as `abc 01>`) indicate command-line prompts, and
the following text is input provided by the user. All other uses of
monospaced text indicate representative output of running a program,
or the contents of a program source file.

[^abc]: Berkeley Logic Synthesis and Verification Group. {ABC}: A
    System for Sequential Synthesis and Verification
    <http://www.eecs.berkeley.edu/~alanmi/abc/>

[^cryptol]: Galois, Inc. Cryptol. <http://corp.galois.com/cryptol>

Setting up the Environment
==========================

\label{sec:setup}

Ensure that `clang`, `llvm-dis`, `lvm-link`, etc., are in your path;
these tools are part of the standard LLVM distribution. Similarly,
make sure that the `lss` executable bundled with this document is in
your path.

Currently, `lss` requires LLVM version 3.0 or 3.1. Due to frequent
changes in the file format for LLVM bitcode, versions before 3.0 are
not supported, and are unlikely to be supported in the future. Support
for LLVM 3.2 is planned for the next release.

All source code used by this tutorial can be found within the
`tutorial/code` subdirectory of the release. There is a Makefile in
that directory that can be used to compile everything with `clang` and
link the resulting object files together. The `check` target can then
be used to start the equivalence checking process. Alternatively, the
next section describes how to manually run the appropriate LLVM tools.
It can be skipped on a first reading.

Generating Bitcode Files
========================

The most common way to generate LLVM bitcode files is through the
`clang` C front-end, available as an optional add-on package to the
LLVM distribution. The `clang` tool is also included in recent
releases of Mac OS X.

Given a C source file, `file.c`, the following command can be used to
generate LLVM bitcode:

    clang -c -emit-llvm file.c

Note, however, that the resulting file is named `file.o` by default,
and the LLVM tools sometimes work better with files that use the `.bc`
extension. So you may want to rename `file.o` to `file.bc`, or use the
command

    clang -c -emit-llvm -o file.bc file.c

The `lss` tool currently works on  a single bitcode file, whereas most
C programs consist of many source  files, each of which compiles to an
individual object (or bitcode) file.  In this context, the `llvm-link`
tool can be useful. The  following command will combine `file1.bc` and
`file2.bc` into `all.bc`.

    llvm-link -o all.bc file1.bc file2.bc

Symbolic Simulation
===================

The LLVM Symbolic Simulator takes the place of a typical
post-compilation execution environment, but makes it possible to
reason about the behavior of programs on a wide range of potential
inputs, rather than a fixed set of test vectors. A standard
post-compilation execution environment for, e.g., clang-compiled
programs, runs programs on concrete input values, producing concrete
results. Symbolic simulation works similarly, but allows inputs to
take the form of symbolic variables that represent arbitrary, unknown
values. The result is then a mathematical formula that describes the
output of the program in terms of the symbolic input variables.

Given a formula representing a program's output, we can then either
evaluate that formula with specific values in place of the symbolic
input variables to get concrete output values, or compare the formula
to another, using known mathematical transformations to prove that the
two are equivalent.

One downside of symbolic simulation, however, is that it cannot easily
handle interaction with the outside world. If a program simply takes
an input, performs some computation, and produces some output,
symbolic simulation can reliably construct a model of that
computation. Cryptographic algorithms typically fall into this
category. In cases where a program does some computation, produces
some output, reads some more input, and continues the computation
based on the new information, we either need a model of the outside
world, or to assume that the input could be completely arbitrary, and
reason about what the program would do for any possible input.

The LLVM Symbolic Simulator can evaluate simple output methods, such
as the ubiquitous `printf`. If the value printed depends on the value
of a symbolic input variable, a bit-level textual representation is
shown with the `?` character used to denote symbolic bits.

The LLVM Symbolic Simulator provides a set of special functions for
performing operations on symbolic values, and for emitting the formal
model representing symbolic values of interest. The rest of this
tutorial will demonstrate how to use these methods to generate a
formal model of a simple AES128 implementation, and then compare this
model to a reference specification.

Supplying Symbolic Input to AES128
==================================

In the `code` subdirectory of this tutorial,
there are some files and directories of note. The file
`aes128BlockEncrypt_driver.c` contains the driver code that sets up
the symbolic inputs to the AES128 block encrypt function;
`aes128BlockEncrypt.[ch]` contains the block encrypt function
implementation; the `AES.cry` file contains the reference
implementation of AES in Cryptol; the `aes.saw` file contains the
equivalence checking SAWScript code; finally, the `Makefile` includes
rules for running LLVM, LSS, and finally SAWScript (the `check` target).

Let's start with `aes128BlockEncrypt_driver.c`. This code creates a
simple wrapper around the `aes128BlockEncrypt` function. We will use
this source file as a running example, and step through what each line
means in the context of symbolic simulation.

Note that the driver includes `sym-api.h` to get access to the special
functions used to interact with the symbolic simulator.
See the `Makefile` for the location of the `sym-api` directory with the
header and implementation files for this API.

The first two variable declarations in the `main` function are those
with the most relevance to symbolic simulation.

    SWord32 *pt  = lss_fresh_array_uint32(4, 0x8899aabbUL);
    SWord32 *key = lss_fresh_array_uint32(4, 0x08090a0bUL);

These declarations each create a new array with entirely symbolic
contents, intended to be used as the plaintext and key inputs to the
block encrypt function. Their size is fixed (4 elements of type
`uint32_t`, or 128 bits), but each element is a symbolic term
representing an arbitrary 32-bit unsigned value. The second parameter
to the `lss_fresh_array_uint32` function is the initial value for each
element if this code is executed in a *concrete* context (i.e., not
via `lss`). We can ignore it for our purposes here.

The next declaration is standard C, and creates an uninitialized
128-bit array for holding the ciphertext result. This does not hold
symbolic values at the time of declaration, but the values stored
inside it will be symbolic if they depend on the values in `pt` or
`key`, as we will expect them to.

Next, calculation of the AES128 ciphertext occurs in a typical
fashion, by calling the block encrypt function and passing both in
parameters and out parameters by pointer.

    aes128BlockEncrypt(pt, key, ct);

The next and final statement does the work of creating a formal model
from the AES128 block encrypt function. This function instructs the
symbolic simulator to generate a formula that describes how the
elements of `ct` depend on the elements of `pt` and `key`, and then
writes that formula to a file called `aes.aig`:

    lss_write_aiger_array_uint32(ct, 4, "aes.aig");

Ultimately, we want to find a formal model that describes the output
of the AES128 block encrypt function, in terms of whatever symbolic
inputs it happens to depend on. In this case, this includes every byte
of the input key and plaintext. However, for some algorithms, it could
include only a subset of the symbolic variables in the program.

The formal model that the simulator generates takes the form of an
And-Inverter Graph (AIG), which is a way of representing a boolean
function purely in terms of the logical operations "and" and "not".
The simplicity of this representation makes the models easy to reason
about, and to compare to models from other sources. However, the same
simplicity means that the model files can be very large in comparison
to the input source code.

Running the Simulator
=====================

To generate a formal model from the example described in the previous
section, we can use the `lss` command, which forms the command-line
front end of the LLVM Symbolic Simulator. At minimum, it needs to know
where to find a fully-linked LLVM bitcode containing a `main`
function. Typing `make` inside the code subdirectory will produce a
file called `aes.bc` that meets these criteria. It works by running
the following commands:

    clang -emit-llvm -I<INC> -c aes128BlockEncrypt.c -o aes128BlockEncrypt.bc
    clang -emit-llvm -I<INC> -c aes128BlockEncrypt_driver.c \
      -o aes128BlockEncrypt_driver.bc
    llvm-link aes128BlockEncrypt.bc aes128BlockEncrypt_driver.bc -o aes.bc

Where `<INC>` is replaced with the directory containing the symbolic
simulator API header file.

The following command will then run `lss` to create a formal model:

    # lss --backend=saw aes.bc

This will result in a file called `aes.aig` that can be further
analyzed using a variety of tools, including SAWScript
and the ABC logic synthesis system from UC Berkeley.

Viewing the Intermediate Representations
========================================

When working with input C source and linked LLVM bitcodes, it can be
usefult to inspect two underlying intermediate representations: LLVM
itself, and LLVM-Sym, the language to which LLVM programs are
translated by `lss`. For example, let's say we've compiled the AES128
driver code by hand:

    clang -emit-llvm -I<INC> -c aes128BlockEncrypt_driver.c \
      -o aes128BlockEncrypt_driver.bc

To see the LLVM assembly language representation of this program, one
can use `llvm-dis`, which produces a `.ll` file containing the
disassembled bitcode:

    llvm-dis aes128BlockEncrypt_driver.bc

Similarly, to view the disassembly after it has been transformed into
the LLVM-Sym representation, the `--xlate` option may be supplied to
`lss`. This option causes the LLVM-Sym representation to be displayed
to stdout; the user may redirect output when convenient:

    lss --backend=saw --xlate aes128BlockEncrypt_driver.bc \
      > aes128BlockEncrypt_driver.sym

When viewing debugging output from `lss`, program locations are
currently shown in reference to the LLVM-Sym representation, so it is
sometimes useful to view that representation alongside `lss` feedback.

Verifying the Formal Model Using SAWScript
==========================================

One easy way to verify an LLVM implementation against a reference
specification is via SAWScript and Cryptol. Cryptol is a
domain-specific language created by Galois for the purpose of writing
high-level but precise specifications of cryptographic algorithms. The
SAWScript language has support for checking the equivalence of
different Cryptol implementations, as well as comparing Cryptol
implementations to external formal models, such as the AIGs
we generated above.

This tutorial comes with a file, `AES.cry`, containing a Cryptol
specification of the AES (a.k.a. Rijndael) cipher. In particular, it
contains the function `blockEncrypt` which should have equivalent
functionality to the `aes128BlockEncrypt` function in our C source.
Well, nearly equivalent: we write a small wrapper around this
function, as can be seen in `AES.cry` that reorders the bytes of
the inputs and outputs as needed to the form expected by the
`blockEncrypt` function. This essentially makes the calling convention
and data layout assumptions of both functions identical before
attempting to show equivalence.

To compare the functionality of the two implementations, we have
several options. As mentioned earlier, formal models can be evaluated
on concrete inputs, or compared to other formal models using proof
techniques to show equivalence for all possible inputs. The contents
of `aes.saw` show how to compare the formal model of the C
implementation against the Cryptol reference specification.

```
...
print "Loading LLVM implementation";
f <- load_aig "aes.aig";
print "Bitblasting Cryptol implementation";
g <- bitblast {{ aesExtract }};
print "Checking equivalence";
res <- cec f g;
print res;
...
```

The `load_aig` line makes the contents of `aes.aig` available as a
an AIG called `f` that takes a 256-bit value as input and
produces 128-bit value as output. The `bitblast` line computes
an AIG representation of the Crypol AES specification and makes it
available as `g`.
Finally, the `cec` line checks that that the functions `f` and `g`
produce the same ciphertext for all possible inputs.

We can load `aes.saw` into the SAWScript interpreter, yielding the
following output:

```
# saw aes.saw
...
Loading LLVM implementation
Bitblasting Cryptol implementation
Checking equivalence
Valid
```

Note that the above actions can be performed by running the `check`
target of the Makefile in the code subdirectory; the proof takes about
15 minutes on the author's laptop.

Alternatively, we could read the LSS produced AIG in as a SAWScript
function, and prove it equal to our Cryptol specification as follows:

```
f <- read_aig "aes.aig";
res <- prove abc {{ \x -> f x == aesExtract x }};
print res
```

In both cases SAWScript uses the ABC tool internally to carry out
the equivalence proof.

Verifying the Formal Model Using ABC
====================================

ABC is a tool for logic synthesis and verification developed by
researchers at UC Berkeley. It can perform a wide variety of
transformations and queries on logic circuits, including those in the
AIG form discussed earlier.

As an alternative approach to the equivalence check from the previous
section, we can use the `cec` command in ABC to attempt to prove the
model generated by the symbolic simulator equivalent to a model
generated from the Cryptol specification.

To generate an AIG model of our Cryptol specification, we use the
`write_aig` command in SAWScript:

```
...
write_aig "aes_ref.aig" {{ aesExtract }};
...
```

Then we can check equivalence in ABC as follows:

```
# abc
UC Berkeley, ABC 1.01 (compiled Feb 13 2015 14:26:08)
abc 01> cec ./aes.aig ./aes-ref.aig
Networks are equivalent.
abc 01>
```

Generating DIMACS CNF Models
============================

In addition to AIG models, LSS can generate models in DIMACS CNF
format for boolean-valued expressions. These models can then be
checked for validity using a SAT solver of your choice.

The AES driver in `aes128BlockEncrypt_driver.c` contains the following
line:

```
lss_write_cnf(!(pt[0] != ct[0] &&
                pt[1] != ct[1] &&
                pt[2] != ct[2] &&
                pt[3] != ct[3]), "noleaks.cnf");
```

This call instructs LSS to write CNF clauses built from the expression
given as the first argument (in this case, an assertion that the plain
text and cipher text are different) into the file given as the second
argument (`noleaks.cnf`). LSS uses the convention that
unsatisfiability of the CNF model corresponds to validity of the given
expression.

We can now use a SAT solver to prove that AES will never encrypt plain
text into identical cipher text (given sufficient time!):

    # picosat noleaks.cnf

Note that we do not guarantee that any currently-available SAT solver
can prove this theorem in a reasonable amount of time.
