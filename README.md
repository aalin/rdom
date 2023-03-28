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

## Getting started

Make sure you have
[Ruby 3.2](https://www.ruby-lang.org/en/downloads/) and
[Bundler](https://bundler.io/),
then run:

    bundle install

To start the server:

    ruby config.ru

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

You can use `bin/transform` to see the transformed output of a Haml-file.

Example:

    bin/transform app/List.haml

## Features and limitations

### Reactive rendering

This repository contains a reactive signals library inspired
by SolidJS, Preact Signals and Reactively.

### Only streaming

Apps made with this can only be streamed, the server will never
attempt to construct the HTML for the initial request.
If you need to serve HTML in the initial request, have a look at
[Mayu Live](https://github.com/mayu-live/framework).

### No resuming

If the connection drops, all state is lost.
For an attempt at something more reliable, check out
[Mayu Live](https://github.com/mayu-live/framework).

### Custom elements

All static DOM trees are extracted into custom elements, so if you write:

```haml
- items = %w[foo bar baz]
%ul
  = items.map do |item|
    %li= item
```

Then this code will be generated:

```ruby
# frozen_string_literal: true
class self::Component < VDOM::Component::Base
  RDOM_Partials = [
    VDOM::CustomElement[
      :"rdom-elem-app꞉꞉my-component.haml-0",
      '<ul><slot id="slot0"></slot></ul>'
    ],
    VDOM::CustomElement[
      :"rdom-elem-app꞉꞉my-component.haml-1",
      '<li><slot id="slot0"></slot></li>'
    ]
  ]
  def render
    items = %w[foo bar baz]
    H[
      RDOM_Partials[0],
      slots: {
        slot0: items.map { |item| H[RDOM_Partials[1], slots: { slot0: item }] }
      }
    ]
  end
end
```

The browser will give you:

```html
<rdom-elem-my-component.haml-0>
  #shadow-dom
    <ul><slot></slot></ul>
    <li>
      <slot id="slot0">
        <rdom-elem-my-component.haml-1> ↴
        <rdom-elem-my-component.haml-1> ↴
        <rdom-elem-my-component.haml-1> ↴
      </slot>
    </li>
  <rdom-elem-my-component.haml-1>
    #shadow-dom
      <li>
        <slot id="slot0">
          <#text> ↴
        </slot>
      </li>
    foo
  </rdom-elem-my-component.haml-1>
  <rdom-elem-my-component.haml-1>
    #shadow-dom
      <li>
        <slot id="slot0">
          <#text> ↴
        </slot>
      </li>
    bar
  </rdom-elem-my-component.haml-1>
  <rdom-elem-my-component.haml-1>
    #shadow-dom
      <li>
        <slot id="slot0">
          <#text> ↴
        </slot>
      </li>
    baz
  </rdom-elem-my-component.haml-1>
</rdom-elem-my-component.haml-0>
```

Each slot inside the shadow DOM will have it's
nodes assigned whenever children are updated.

This is good for several reasons:

* Markup is only transferred to the browser once and can be reused.
* Diffing becomes easier because we don't have care about order.
  [HTMLSlotElement.assign()](https://developer.mozilla.org/en-US/docs/Web/API/HTMLSlotElement/assign)
  updates the order of children in 1 call.
  Most VDOM libraries use the use the famous 2-way-diffing algorithm,
  which is difficult to get right.

Each custom element has `:host { display: contents; }` to avoid
interference with flex and grid.
