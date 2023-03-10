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

Currently trying to achieve this:

**input**
```haml
:ruby
  # setup
:ruby
  items = %w[foo bar baz]
%div
  %ul
    = items.map do |item|
      %li= item
```

**output**
```ruby
# frozen_string_literal: true
class self::Component < VDOM::Component::Base
  Partial_qeurtua4rb =
    CustomElement.new(
      name: "rdom-elem-qeurtua4rb",
      template: '<div><ul><slot name="slot0"></slot></ul></div>'
    )
  Partial_2vaz9fi4yr =
    CustomElement.new(
      name: "rdom-elem-2vaz9fi4yr",
      template: '<li><slot name="slot0"></slot></li>'
    )
  # setup
  def render
    items = %w[foo bar baz]
    H[
      Partial_qeurtua4rb,
      slots: {
        slot0:
          items.map { |item| H[Partial_2vaz9fi4yr, slots: { slot0: item }] }
      }
    ]
  end
end
```

Which should render something like this:

```html
<rdom-elem-qeurtua4rb>
  #shadow-root
    <div>
      <ul>
        <slot name="slot0"></slot>
      </ul>
    </div>
  <rdom-elem-2vaz9fi4yr>
    #shadow-root
      <li><slot name="slot0"></slot></li>
    #text(foo)
  </rdom-elem-2vaz9fi4yr>
  <rdom-elem-2vaz9fi4yr>
    #shadow-root
      <li><slot name="slot0"></slot></li>
    #text(foo)
  </rdom-elem-2vaz9fi4yr>
  <rdom-elem-2vaz9fi4yr>
    #shadow-root
      <li><slot name="slot0"></slot></li>
    #text(bar)
  </rdom-elem-2vaz9fi4yr>
</rdom-elem-qeurtua4rb>
```

And then all children with that slot would be set using [slot.assign()](https://developer.mozilla.org/en-US/docs/Web/API/HTMLSlotElement/assign).

[Link to prototype](https://flems.io/#0=N4IgtglgJlA2CmIBcBWAnAOgBwGYA0IAxgPYB2AzsQskVbAIYAO58UIBAZhAucgNqhS9MIiQgMACwAuYWO1qkp8RTRABfPIOGjxAK14ESi5VJocArqUJSIZAASEATvHpKAKvDCMGSgBTTZAEo7YAAdUjsHMnIpOyUvH3g7AF47KGJCcxFFDCcXJQBRBGypXwByeO9XeDLA8MjKxIwIUlJ4RwAJNwBZABkUuwDYertnKXNHCMbq8LVwiysbeyh4LjaAYXMY4jAizxNfIRE8QZlYYLCIqIpY6aUBvOqPBOr-M8CAbhHM7d3ik3IGBWa3gvhGkSO8Dw4IcDHI5Ds8AAHkpSFAEV0+nsSiEYZEjG1rKx1vRYLAAEb0QgAa18FzxkTsEA4dl8AEIpBIIIDyBJ6OkAO4AJWIxCk9KujKlcS5gNcUipEgAynzBb5LtLNXYwMQVkg7KEQMRGMpDdDJVrIuRYGKAILwiAAc1IJX1hrA9FI5lJZoZUrUgQwTBNaN8d3guTIqKkuRtbQAcrrQVJHOZ4IE6hb-X6ZdygdzGK5CBICgA3A5tAV2MsHMoE+BEqC1TOauZZuz0B3OpU20qQk4YQekJPkCWW5mszl57nrMiEpRQMeW3NyxghqC+QcYYcrQFcWBKRy+Q5J4LJAB8dh3EcLzkUdjZyVSU9HLeXL4wvP5xGFoqkOalDAAEc00cABPJV4AQaxiCPAADa0xT4SFkgAEmASE1AAXTgt9lzsIMu1ITchxHPDpTURFYBYXF2ylD9+SgGtFF6blUXaME6OlOs5wbBcynNfDIjpFJLwYoiezFQ5tAHUjd0CQShOAOwyEIeB9RTNM7DbfDyOzLixgmKZZQZHTGTMzM22BFp4E2X5sQOEY6y2KQdgAWlgNiBJGOCAB5zFgOwYjAhBkkNTyYjc4KEDcqQwJNfUVkICAPVgL4QHPXzENiFDDWLbgoDvQ1MoAemy0qAvPODwkzayNhcnYHMUTjImc343IgeJvKuPzPMy7Kr20MKiC5WBCtNDLfLK3tSr66rSEzcIjBiOwItiVJ0kyEpcmcaomtKNrXLADyvNqjIshMDByV1MCgzXZQNzWxarGiWJ8rGu8Bj4Q16DNA0QHJP68qBkAOFFEHKUcCH6AAL0NLCMA9RhjxiRwz0vDVRngcZJlZGFNouxQGR2-J4H28ofiOjqur0gjO3IJ1SEkg73vG0gBLSc7tsedxkSkRMVl8VGMxGSznpYKQAEljEcUtSWPdHaMiNbCIZ7tewp0a2Y5rdWbvN89eUDBnHLRwWDpWYTgARgABjtwJ5BYaClgoGgACYbaQG23JwHAkAAdnUTQQEhGhcnheQjGjVRsLUIA)
