# Anix
Extremely experimental operating system concept for OpenComputers.

## What is Anix

Anix is an asynchronous OS that forces safe practices onto running programs. It uses a global thread model with grouping to ensure security while remaining fast. Kernel Objects are used as communication channels and trusted handles (randomly generated integers attached to a Kernel Object that CANNOT be spoofed otherwise).

Processes follow a [Dart-like](https://dartlang.org/) model where threads can wait on events.

### Kernel Objects

In Anix there are 7 different Kernel Objects. Kernel Objects cannot move outside of their owner processes. During data marshalling, Kernel Objects are cloned and owned by the destination process. Kernel Objects can be deleted at any time to manually free up resources. Lua's garbage collector can delete Kernel Objects automatically.

#### ReadStream and WriteStream

A ReadStream and WriteStream combo is created using the ```kobject.newStream()``` method. WriteStreams enqueue events in each of it's ReadStream's mailboxes. The ReadStreams react to the events in the mailbox. When a ReadStream receives a piece of data, it creates a new thread and sends it to it's listener callback. New threads are created so that ```await()``` and ```yield()``` work properly and do not stop the ReadStream from reading it's queue.

#### Futures and Completers

A Future and Completer combo is created using the ```kobject.newFuture()``` method. A completer exposes a ```:complete(...)``` method that invokes the Future object on the other end. Like the ReadStream, the Future object runs it's callback in a new thread. Future objects can only be completed once. Any attempts at using a completed future object will result in "attempt to use deleted object" errors.

#### Handles

A handle is a secure reference to a randomly generated integer value. Because handles cannot be spoofed by any processes, they are used as a means to refer to an object that cannot leave it's current process (For example, Filesystem Handles from the Filesystem process). Internally the Handle generates integers using xorshift. This is used because of the global state nature of math.random in Lua.

#### Exports and ExportClients

Exports are an easy way to export an RPC interface to other processes. Currently, exports are used to implement system services. Exports are, in essence, specialized stream objects that return a Future that triggers when the other side completes it's task. Export objects are not Marshallable, but ExportClients are.
