Links and Receivers
===================

So-called _links_ are _receivers_ are terms referred to throughout the documentation
and understanding what they are and how they relate to each other is important for what
is to follow.

## The `Link`

A _Link_ is provides us with a method to send data to a destination link-layer address
and be notified when we receive packets from link-layer addressed hosts over said link.

A _link_ is composed out of a few things:

1. A list of _receivers_
    * These are the currently attached receivers which is to be called
    serially (one after the other) whenever a data packet arrives over
    this link.
    * Given a link with two `Receiver`(s) attached, then in an example
    whereby the bytes `[66, 65, 65, 66]` arrive over the link then that
    that byte array would be copied to the attached
2. A _source address_
    * We must have a way to determine the source address of the link
    such that it can be used for various procedures such as ARP
3. A _transmission_ and _broadcast_ mechanism
    * We need a way to send unicast (traffic directed to a singular _given_
    host) and also to broadcast to all those attached to the link

### Concrete methods

There are a few methods which relate to the `Receiver`(s). These are shown below and essentially are for adding,
removing and enumerating receivers for this link:

| Method name                              | Description                                                                               |
|------------------------------------------|-------------------------------------------------------------------------------------------|
| `attachReceiver(Receiver receiver)`      | This attaches the given receiver to this `Link`, meaning packets will be copied to it     |
| `removeReceiver(Receiver receiver)`      | Removes the given receiver from this `Link` meaning that packets will no longer be copied to it |
| `auto getRecvCnt()`                      | Returns the number of receivers attached to this `Link`                                   |

#### Implementing your driver

As part of implementing your driver, i.e. by method of extending/sub-classing the `Link` class, you will implement the mechanism (however
you go about it) by which will extract data from your link-layer and extract the network-layer part (the twine data payload of your
link-layer packet)

> and then what do you do with it?

Well, you will want to make this data available to any of the `Receiver`(s) which are attached currently. you want to _pass it up_ to the handlers. This can be safely done by calling the `receive(...)` method as shown below:

| Method name                              | Description                                                                               |
|------------------------------------------|-------------------------------------------------------------------------------------------|
| `receive(byte[] recv, string srcAddr)`   | This is to be called when the `Link` sub-class (implementation) has network-layer traffic to provide  |

Note that the `srcAddr` must contain the network-layer source address.

### Abstract methods

TODO: Talk about what needs to be overridemn

| Method name                              | Description                                                                               |
|------------------------------------------|-------------------------------------------------------------------------------------------|
| `void transmit(byte[] xmit, string addr)`| Link-implementation specific for driver to send data to a specific destination address    |
| `void broadcast(byte[] xmit)`            | Link-implementation specific for driver to broadcast to all hosts on its broadcast domain |
| `string getAddress()`                    | Link-implementation specific for driver to report its address                             |

