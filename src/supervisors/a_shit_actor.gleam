//// This module implements a shit actor that crashes every now and then.
//// Having an actor that fails every now and then will help us test out our supervisors.
//// If you need a refresher on actors, go revisit the `actor.gleam` and `actor/pantry` code.
//// 
//// Alright, let's implement of game of Duck Duck Goose as an actor.
//// 
//// (If this game is unfamiliar to you, children sit in a circle while 
//// one of them walks around behind the rest tapping them and saying "duck"
//// or "goose". They say "duck" for awhile, and nothing happens, but when 
//// they choose the "goose" all hell breaks loose and they chase each other 
//// around the circle. Interestingly in the midwest of the United States the
//// game is often called "Duck, Duck, Grey Duck".)

import gleam/erlang/process.{type Subject}
import gleam/otp/actor
import prng/random

/// Okay, well this is new.
/// We're going to hand this actor off to supervisor,
/// which will manage starting it for us.
/// 
/// That means we can't simply get the subject out from 
/// the return, since we dont call the start function
/// directly. Instead, we'll have to send the subject
/// to the parent process when the actor starts up.
/// 
/// The `actor.start_spec` function gives us more fine-grained
/// control over how the actor gets created. We get to
/// provide a startup function to produce the initial state,
/// instead of simply providing the initial state directly.
/// 
/// We'll take advantage of getting the chance to compute
/// things on the new process to send ourselves back a subject
/// for the actor.
/// 
/// This isn't a hack, it's the intended design. The subject
/// produced by the `actor.start_spec` function is for the
/// supervisor to use, not for us to use directly.
fn actor_child(init init, loop loop) {
  actor.new_with_initialiser(50, init)
  |> actor.on_message(loop)
  |> actor.start
}

pub fn start(
  parent_subject: Subject(Subject(Message)),
) -> fn() -> Result(actor.Started(Nil), actor.StartError) {
  fn() {
    actor_child(
      init: fn(_) {
        let actor_subject = process.new_subject()
        process.send(parent_subject, actor_subject)
        let selector =
          process.new_selector()
          |> process.select(actor_subject)

        Ok(
          actor.initialised(Nil)
          |> actor.selecting(selector),
        )
      },
      loop: handle_message,
    )
  }
}

/// We provide this function in case we want to manually stop the actor,
/// but in reality the supervisor will handle that for us.
pub fn shutdown(subject: Subject(Message)) -> Nil {
  actor.send(subject, Shutdown)
}

/// This is how we play the game.
/// We are at the whim of the child as to whether we are a 
/// humble duck or the mighty goose.
pub fn play_game(subject: Subject(Message)) -> Result(String, Nil) {
  // -> Result(String, process.CallError(String)) {
  let msg_generator = random.weighted(#(90.0, Duck), [#(10.0, Goose)])
  let msg = random.random_sample(msg_generator)

  process.call(subject, 1000, msg)
}

/// This is the type of messages that the actor will receive.
/// Remember, any time we want to reply to a message, that message
/// must contain a subject to reply with.
pub type Message {
  Duck(client: Subject(Result(String, Nil)))
  Goose(client: Subject(Result(String, Nil)))
  Shutdown
}

/// And finally, we play the game
fn handle_message(state: Nil, message: Message) -> actor.Next(Nil, Message) {
  case message {
    Duck(client) -> {
      actor.send(client, Ok("duck"))
      actor.continue(state)
    }
    Goose(client) -> {
      actor.send(client, Error(Nil))
      actor.stop_abnormal("goose!!!!")
    }
    Shutdown -> {
      actor.stop()
    }
  }
}
