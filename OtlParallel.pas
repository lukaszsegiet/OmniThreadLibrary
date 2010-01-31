///<summary>High-level parallel execution management.
///    Part of the OmniThreadLibrary project. Requires Delphi 2009 or newer.</summary>
///<author>Primoz Gabrijelcic</author>
///<license>
///This software is distributed under the BSD license.
///
///Copyright (c) 2010 Primoz Gabrijelcic
///All rights reserved.
///
///Redistribution and use in source and binary forms, with or without modification,
///are permitted provided that the following conditions are met:
///- Redistributions of source code must retain the above copyright notice, this
///  list of conditions and the following disclaimer.
///- Redistributions in binary form must reproduce the above copyright notice,
///  this list of conditions and the following disclaimer in the documentation
///  and/or other materials provided with the distribution.
///- The name of the Primoz Gabrijelcic may not be used to endorse or promote
///  products derived from this software without specific prior written permission.
///
///THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND
///ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
///WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
///DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER OR CONTRIBUTORS BE LIABLE FOR
///ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
///(INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
///LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON
///ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
///(INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
///SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
///</license>
///<remarks><para>
///   Author            : Primoz Gabrijelcic
///   Creation date     : 2010-01-08
///   Last modification : 2010-01-14
///   Version           : 1.0
///</para><para>
///   History:
///     1.0: 2010-01-14
///       - Released.
///</para></remarks>

// http://msdn.microsoft.com/en-us/magazine/cc163340.aspx
// http://blogs.msdn.com/pfxteam/archive/2007/11/29/6558543.aspx
// http://cis.jhu.edu/~dsimcha/parallelFuture.html

(* Things to consider:
   - Introduce cancellation token.
   - Common look and feel for all control structures in Parallel.
   - Support for simpler IEnumerable source (with "lock and fetch a packet" approach).
   - All Parallel stuff should have a "chunk" option (or default).
       int P = 2 * Environment.ProcessorCount; // assume twice the procs for
                                               // good work distribution
       int Chunk = N / P;                      // size of a work chunk
   - Parallel.ForRange(start, stop[, step])
     - can be converted into normal enumerable style (at least for now)
   - Parallel.Do (fork/join)

   Can something like this be implemented?:
     "To scale well on multiple processors, TPL uses work-stealing techniques to
      dynamically adapt and distribute work items over the worker threads. The library
      has a task manager that, by default, uses one worker thread per processor. This
      ensures minimal thread switching by the OS. Each worker thread has its own local
      task queue of work to be done. Each worker usually just pushes new tasks onto its
      own queue and pops work whenever a task is done. When its local queue is empty,
      a worker looks for work itself and tries to "steal" work from the queues of
      other workers."
*)

unit OtlParallel;

interface

uses
  SysUtils,
  OtlCommon,
  OtlTask;

type
  IOmniParallelLoop = interface;

  TOmniAggregatorDelegate = reference to function(const aggregate, value: TOmniValue): TOmniValue;

  TOmniIteratorDelegate = reference to procedure(const loop: IOmniParallelLoop;
    const value: TOmniValue);
  TOmniIteratorAggregateDelegate = reference to function(const loop: IOmniParallelLoop;
    const value: TOmniValue): TOmniValue;

  TOmniSimpleIteratorDelegate = reference to procedure(const value: TOmniValue);
  TOmniSimpleIteratorAggregateDelegate = reference to function(const value: TOmniValue): TOmniValue;

  // *** assumes that the enumerator's Take method is threadsafe ***
  IOmniParallelAggregatorLoop = interface ['{E430F270-1C5D-49A7-92E3-283753801764}']
    function  Execute(loopBody: TOmniIteratorAggregateDelegate): TOmniValue; overload;
    function  Execute(loopBody: TOmniSimpleIteratorAggregateDelegate): TOmniValue; overload;
  end; { IOmniParallelAggregatorLoop }

  // *** assumes that the enumerator's Take method is threadsafe ***
  IOmniParallelLoop = interface ['{ACBFF35A-FED9-4630-B442-1C8B6AD2AABF}']
    function  Aggregate(aggregator: TOmniAggregatorDelegate): IOmniParallelAggregatorLoop ; overload;
    function  Aggregate(aggregator: TOmniAggregatorDelegate;
      defaultAggregateValue: TOmniValue): IOmniParallelAggregatorLoop; overload;
    procedure Execute(loopBody: TOmniIteratorDelegate); overload;
    procedure Execute(loopBody: TOmniSimpleIteratorDelegate); overload;
    function  NumTasks(taskCount : integer): IOmniParallelLoop;
    procedure Stop;
  end; { IOmniParallelLoop }

  Parallel = class
    class function  ForEach(const enumGen: IOmniValueEnumerable): IOmniParallelLoop; overload;
    class function  ForEach(low, high: int64): IOmniParallelLoop; overload;
    class procedure Join(const task1, task2: TProc); overload;
    class procedure Join(const tasks: array of TProc); overload;
  end; { Parallel }

implementation

uses
  Windows,
  GpStuff,
  OtlSync,
  OtlTaskControl;

{ TODO 3 -ogabr : Should work with thread-unsafe enumerators }

type
  TOmniParallelLoop = class(TInterfacedObject, IOmniParallelLoop, IOmniParallelAggregatorLoop)
  strict private
    oplAggregate : TOmniValue;
    oplAggregator: TOmniAggregatorDelegate;
    oplEnumGen   : IOmniValueEnumerable;
    oplNumTasks  : integer;
    oplStopped   : boolean;
  public
    constructor Create(const enumGen: IOmniValueEnumerable);
    function  Aggregate(aggregator: TOmniAggregatorDelegate):
      IOmniParallelAggregatorLoop; overload;
    function  Aggregate(aggregator: TOmniAggregatorDelegate;
      defaultAggregateValue: TOmniValue): IOmniParallelAggregatorLoop; overload;
    function  Execute(loopBody: TOmniSimpleIteratorAggregateDelegate): TOmniValue; overload;
    function  Execute(loopBody: TOmniIteratorAggregateDelegate): TOmniValue; overload;
    procedure Execute(loopBody: TOmniSimpleIteratorDelegate); overload;
    procedure Execute(loopBody: TOmniIteratorDelegate); overload;
    function  NumTasks(taskCount: integer): IOmniParallelLoop;
    procedure Stop;
  end; { TOmniParallelLoop }

{ Parallel }

class function Parallel.ForEach(const enumGen: IOmniValueEnumerable): IOmniParallelLoop;
begin
  { TODO 3 -ogabr : In Delphi 2010 RTTI could be used to get to the GetEnumerator from base object }
  Result := TOmniParallelLoop.Create(enumGen);
end; { Parallel.ForEach }

class procedure Parallel.Join(const task1, task2: TProc);
begin
  Join([task1, task2]);
end; { Parallel.Join }

class function Parallel.ForEach(low, high: int64): IOmniParallelLoop;
begin
  raise ENotSupportedException.Create('Not implemented');
  { TODO 1 : Implement: Parallel.ForEach }
end; { Parallel.ForEach }

class procedure Parallel.Join(const tasks: array of TProc);
begin
  raise ENotSupportedException.Create('Not implemented');
  { TODO 1 : Implement: Parallel.Join }
end; { Parallel.Join }

{ TOmniParallelLoop }

constructor TOmniParallelLoop.Create(const enumGen: IOmniValueEnumerable);
begin
  inherited Create;
  oplEnumGen := enumGen;
  oplNumTasks := Environment.Process.Affinity.Count;
end; { TOmniParallelLoop.Create }

function TOmniParallelLoop.Aggregate(aggregator: TOmniAggregatorDelegate):
  IOmniParallelAggregatorLoop;
begin
  Result := Aggregate(aggregator, TOmniValue.Null);
end; { TOmniParallelLoop.Aggregate }

function TOmniParallelLoop.Aggregate(aggregator: TOmniAggregatorDelegate;
  defaultAggregateValue: TOmniValue): IOmniParallelAggregatorLoop;
begin
  oplAggregator := aggregator;
  oplAggregate := defaultAggregateValue;
end; { TOmniParallelLoop.Aggregate }

function TOmniParallelLoop.Execute(loopBody: TOmniSimpleIteratorAggregateDelegate): TOmniValue;
begin
  Result := Execute(
    function(const loop: IOmniParallelLoop; const value: TOmniValue): TOmniValue
    begin
      Result := loopBody(value);
    end);
end; { TOmniParallelLoop.Execute }

function TOmniParallelLoop.Execute(loopBody: TOmniIteratorAggregateDelegate): TOmniValue;
var
  countStopped : IOmniResourceCount;
  iTask        : integer;
  lockAggregate: IOmniCriticalSection;
begin
  oplStopped := false;
  countStopped := TOmniResourceCount.Create(oplNumTasks);
  lockAggregate := CreateOmniCriticalSection;
  for iTask := 1 to oplNumTasks do
    CreateTask(
      procedure (const task: IOmniTask)
      var
        aggregate : TOmniValue;
        value     : TOmniValue;
        enumerator: IOmniValueEnumerator;
      begin
        aggregate := TOmniValue.Null;
        enumerator := oplEnumGen.GetEnumerator;
        while (not oplStopped) and enumerator.Take(value) do
          oplAggregator(aggregate, loopBody(Self, value));
        task.Lock.Acquire;
        try
          oplAggregator(oplAggregate, aggregate);
        finally task.Lock.Release; end;
        countStopped.Allocate;
      end,
      'Parallel.ForEach worker #' + IntToStr(iTask)
    ).WithLock(lockAggregate)
     .Unobserved
     .Schedule;
  WaitForSingleObject(countStopped.Handle, INFINITE);
end; { TOmniParallelLoop.Execute }

procedure TOmniParallelLoop.Execute(loopBody: TOmniIteratorDelegate);
var
  countStopped: IOmniResourceCount;
  iTask       : integer;
begin
  oplStopped := false;
  countStopped := TOmniResourceCount.Create(oplNumTasks);
  for iTask := 1 to oplNumTasks do
    CreateTask(
      procedure (const task: IOmniTask)
      var
        value     : TOmniValue;
        enumerator: IOmniValueEnumerator;
      begin
        enumerator := oplEnumGen.GetEnumerator;
        while (not oplStopped) and enumerator.Take(value) do
          loopBody(Self, value);
        countStopped.Allocate;
      end,
      'Parallel.ForEach worker #' + IntToStr(iTask)
    ).Unobserved
     .Schedule;
  WaitForSingleObject(countStopped.Handle, INFINITE);
end; { TOmniParallelLoop.Execute }

procedure TOmniParallelLoop.Execute(loopBody: TOmniSimpleIteratorDelegate);
begin
  Execute(
    procedure (const loop: IOmniParallelLoop; const elem: TOmniValue)
    begin
      loopBody(elem);
    end);
end; { TOmniParallelLoop.Execute }

function TOmniParallelLoop.NumTasks(taskCount: integer): IOmniParallelLoop;
begin
  Assert(taskCount > 0);
  oplNumTasks := taskCount;
  Result := Self;
end; { TOmniParallelLoop.taskCount }

procedure TOmniParallelLoop.Stop;
begin
  oplStopped := true;
end; { TOmniParallelLoop.Stop }

end.