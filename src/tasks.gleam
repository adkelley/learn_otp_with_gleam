//// Tasks are one off processes meant to easily make synchronous work async.
//// They're really straightforward to use, just fire them off and check back later.
//// The gleam_otp.tasks (0.16.1) module was not upgraded to gleam_otp 1.0.0.
//// I suspect the the thinking is that, because they are mereil conveniences for
//// spawning and awaiting tasks, it should not be part of gleam_otp
//// I suspect the the thinking is that, because tasks are merely conveniences for
//// spawning and awaiting tasks, it should not be part of gleam_otp. Consequently,
//// I've taken the liberpy of porting of the module myself in tasks/task.gleam

import birl
import birl/duration
import gleam/dict.{type Dict}
import gleam/dynamic.{type Dynamic}
import gleam/erlang/process
import gleam/int
import gleam/io
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import simplifile
import tasks/task

pub fn main() {
  // Do a thing in a different process
  // Note that this task is eager, it will start immediately
  let handle =
    task.async(fn() {
      process.sleep(500)
      io.println("Task is done")
    })

  // Do some other stuff while the task is running
  io.println("I will execute right away")

  // When you need the result, block until it's done
  task.await(handle, 1000)

  // Now that the task is done, we can do more stuff
  io.println("I won't execute until the task is done.")

  // There's a problem with the code above. If the task times out, 
  // the current process will crash! Most of the time, you don't want that.
  // You can use `task.try_await` to handle the timeout gracefully.

  let handle = task.async(fn() { process.sleep(1000) })

  case task.try_await(handle, 500) {
    Ok(_) -> io.println("Task finished successfully")
    // This is the one that will execute
    Error(_) -> io.println("Task timed out!")
  }

  //
  // FOOTGUN ALERT!: `task.try_await` will only protect you from a timeout or a "crash" (the process exiting).
  // If the task panics (which is subtly different than an exit), the current process will panic too!
  //
  // If you're thinking "That's kinda shit, what if I want to handle panicked
  // processes gracefully as well?", well, OTP has amazing constructs for that
  // called supervisors. It'd rather you use those than roll your own
  // shitty version.
  //
  // If you REALLY want to handle panicking tasks yourself, there's a function
  // called [rescue](https://hexdocs.pm/gleam_erlang/gleam/erlang.html#rescue)
  // which takes any function and converts a panic into a result.
  // It's really meant for handling exceptions thrown in ffi erlang/elixir 
  // code though, you shouldn't need it when operating from the relative safety 
  // of Gleam land

  let assert Error(_) = rescue(fn() { panic })

  // And an example using it with tasks, shame on you for ignoring my sage advice.
  let assert Error(_) =
    task.await(task.async(fn() { rescue(fn() { panic }) }), 1000)

  // To be clear, we're talking about protecting you from weird hard to
  // uncover concurrency bugs and network issues. Gleam's static typing
  // and immutability will do a good job protecting you from the run of the 
  // mill index out of bounds/foo is undefined bullshit. 
  // Just have your task return a `Result`

  let handle = task.async(fn() { list.find([1, 2, 3], fn(x) { x == 4 }) })

  case task.await(handle, 1000) {
    Ok(val) -> io.println("The 100th item is" <> int.to_string(val))
    Error(Nil) -> io.println_error("The list has fewer than 100 items")
  }

  // Alright, let's do a concurrency hello world example: Parallel Letter Frequency.
  // We'll write a function that takes a list of codepoints and counts the frequency each one 
  // appears. We use a list of codepoints instead of a string because dealing with graphemes 
  // properly just distracts from the point of this exercise.

  // Side note: If Gleam error handling is confusing for you, I've written [a short blog
  // post on the subject](https://www.benjaminpeinhardt.com/error-handling-in-gleam/)
  use workload <- result.try(simplifile.read("./src/tasks/king_james_bible.txt"))
  let workload = string.to_utf_codepoints(workload)

  // Doing work concurrently is about finding work that can be split into repeatable
  // chunks. Therefore when trying to split work into parts, it's usually a good idea 
  // to start with the simple linear version then try to reuse it :) 

  let linear_freq =
    time("linear frequency", fn() { linear_letter_frequency(workload) })

  // Okay, now that that's working, let's split the work into appropriate chunks
  // and do the chunks in separate tasks

  let parallel_freq =
    time("parallel frequency", fn() {
      parallel_letter_frequency(workload, 200_000)
    })

  // Little sanity check
  case linear_freq == parallel_freq {
    True ->
      io.println(
        "Our parallel and linear frequency functions produced the same output",
      )
    False ->
      io.println(
        "Our parallel and linear frequency functions produced different output",
      )
  }

  // Returning an OK because we used result.try
  Ok(Nil)
}

// This is our base linear implementation for comparison. Hopefully it makes sense.
// We fold over the list and for each codepoint we increment it's value in the list.
fn linear_letter_frequency(input: List(UtfCodepoint)) -> Dict(UtfCodepoint, Int) {
  use acc, letter <- list.fold(input, dict.new())
  use entry <- dict.upsert(acc, update: letter)
  case entry {
    Some(n) -> n + 1
    None -> 1
  }
}

// This is our parallel/concurrent implementation
// (If your computer has multiple cores, Erlang should automagically use them and make
// this properly parallel)
fn parallel_letter_frequency(
  input: List(UtfCodepoint),
  chunk_size: Int,
) -> Dict(UtfCodepoint, Int) {
  // Create chunks of work and pass them to separate tasks to be worked on
  let handles =
    list.map(list.sized_chunk(input, chunk_size), fn(chunk) {
      task.async(fn() { linear_letter_frequency(chunk) })
    })

  // Fold over the handles to the tasks to await their results
  use total_freq, partial_freq_handle <- list.fold(handles, dict.new())
  let partial_freq = task.await(partial_freq_handle, 1000)

  // Merge the results into a single structure as they come in.
  // We fold over the partial mapping we got back from the task 
  // and update the total count with it.
  // 
  // Notice we do this inside the fold of the task handles rather than in another loop. 
  // We don't want to await the next task until we're out of work to do.

  use total_freq, letter, count <- dict.fold(partial_freq, total_freq)
  use entry <- dict.upsert(total_freq, letter)
  case entry {
    Some(old_count) -> old_count + count
    None -> count
  }
}

// This is just a little timer function to help use see the results of our work.
fn time(name: String, f: fn() -> a) -> a {
  let start = birl.now()
  let x = f()
  let end = birl.now()
  let difference =
    birl.difference(end, start) |> duration.blur_to(duration.MilliSecond)
  io.println(name <> " took: " <> int.to_string(difference) <> "ms")
  x
}

// Alright, if you made it through all this, head on over to actors.gleam to see how more 
// long running concurrent operations are handled.

// region:    --- FFI
/// Gleam doesn't offer any way to raise exceptions, but they may still occur
/// due to bugs when working with unsafe code, such as when calling Erlang
/// function.
///
/// This function will catch any error thrown and convert it into a result
/// rather than crashing the process.
///
@external(erlang, "rescue_ffi", "rescue")
pub fn rescue(a: fn() -> a) -> Result(a, Crash)

pub type Crash {
  Exited(Dynamic)
  Thrown(Dynamic)
  Errored(Dynamic)
}
// endregion: --- FFI
