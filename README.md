# rdom

Reactive DOM updates with Ruby.

🔥 live demo at [rdom.fly.dev](https://rdom.fly.dev/)

🚀 embedding demo at [rdom.netlify.app](https://rdom.netlify.app/)

## Description

This is a basic experiment with a server side VDOM in Ruby.
For a more complete implementation, see
[Mayu Live](https://github.com/mayu-live/framework).
I had some ideas that I felt like I had to explore,
and this is the result.

## Server

This thing comes with an HTTP/2 server.
Start it with `ruby config.ru`.

By default it binds to `https://localhost:8080`,
but it can be changed by setting the environment variable
`RDOM_BIND` like this `RDOM_BIND="https://[::]" ruby config.ru`.

## Embedding

These are the only lines of HTML you need to mount an app.

```html
<script type="module" src="https://rdom.fly.dev/rdom.js"></script>
<rdom-embed src="https://rdom.fly.dev/.rdom"></rdom-embed>
```

## Transforms

This program reads `app/App.rb` and performs the following transforms:

* Add `frozen_string_literal: true` to the top of the file.
* Transform `@foo` to `self.state[:foo]`.
* Transform `@foo = 123` to `self.update { self.state[:foo] = 123 }`.
* Transform `$foo` to `self.props[:foo]`.

Code within [backticks](https://ruby-doc.org/3.2.0/Kernel.html#method-i-60)
and [heredocs](https://ruby-doc.org/3.2.0/syntax/literals_rdoc.html#label-Here+Document+Literals)
identified by HTML, will be parsed, and tags will be transformed into Ruby code.

Then it creates a class that inherits from `Component::Base`,
and calls methods on it asynchronously.

## Getting started

Make sure you have Ruby 3.2 and bundler, then run:

    bundle install

To start the thing, type:

    ruby config.ru

## Limitations

### No resuming

If the connection drops, all state is lost.

### Reordering is broken

`VDOM::Nodes::VChild` has a position hash which is calculated to be
between the previous and next node. The idea is that if the position
changes, then the position should update in the DOM.

This worked great when I tried it on paper, however I can't get it to work.
