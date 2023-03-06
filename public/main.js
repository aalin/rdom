customElements.define(
  "vdom-root",
  class VDOMRoot extends HTMLElement {
    constructor() {
      super();

      this.start(
        this.attachShadow({ mode: "open" })
      )
    }

    async start(root) {
      const res = await fetch(
        "/stream",
        { method: "POST" },
      );

      const sessionId = res.headers.get("x-rdom-session-id")

      res.body
        .pipeThrough(new TextDecoderStream())
        .pipeThrough(initJSONDecoder())
        .pipeTo(initPatcherStream({
          nodes: new Map(),
          root,
          sessionId,
        }))
    }
  }
);

function initJSONDecoder() {
  return new TransformStream({
    start(controller) {
      controller.buf = ''
      controller.pos = 0
    },

    transform(chunk, controller) {
      controller.buf += chunk
      console.log({chunk})

      while (controller.pos < controller.buf.length) {
        if (controller.buf[controller.pos] === '\n') {
          const line = controller.buf.substring(0, controller.pos)
          controller.enqueue(JSON.parse(line))
          controller.buf = controller.buf.substring(controller.pos + 1)
          controller.pos = 0
        } else {
          controller.pos++
        }
      }
    }
  })
}

function initPatcherStream(app) {
  return new WritableStream({
    write(message) {
      console.log(message)
      const [type, ...args] = message;
      const fn = functions[type]

      if (!fn) {
        console.error("Not implemented:", type)
        return
      }

      fn.apply(app, args)
    }
  })
}

const functions = {
  CreateRoot(sessionId) {
    this.nodes.set(null, this.root);
  },
  CreateElement(id, type) {
    this.nodes.set(id, document.createElement(type))
  },
  InsertBefore(parentId, id, refId) {
    this.nodes.get(parentId).insertBefore(
      this.nodes.get(id),
      refId && this.nodes.get(refId),
    )
  },
  RemoveChild(parentId, id) {
    this.nodes.get(parentId).removeChild(this.nodes.get(id))
  },
  RemoveNode(id) {
    this.nodes.get(id).remove()
    this.nodes.delete(id)
  },
  CreateTextNode(id, content) {
    this.nodes.set(id, document.createTextNode(content))
  },
  SetTextContent(id, content) {
    this.nodes.get(id).textContent = content
  },
  ReplaceData(id, offset, count, data) {
    this.nodes.get(id).replaceData(offset, count, data)
  },
  InsertData(id, offset, data) {
    this.nodes.get(id).insertData(offset, data)
  },
  DeleteData(id, offset, count) {
    this.nodes.get(id).deleteData(offset, count)
  },
  SetAttribute(id, name, value) {
    if (name === "value") {
      this.nodes.get(id).value = value
      return
    }
    this.nodes.get(id).setAttribute(name, value)
  },
  RemoveAttribute(id, name) {
    this.nodes.get(id).removeAttribute(name)
  },
  CreateDocumentFragment(id) {
    this.nodes.set(id, document.createDocumentFragment())
  },
  SetCSSProperty(id, name, value) {
    this.nodes.get(id).style.setProperty(name, value)
  },
  RemoveCSSProperty(id, name) {
    this.nodes.get(id).style.removeProperty(name)
  },
  SetHandler(id, event, callbackId) {
    this.nodes.set(callbackId,
      this.nodes.get(id).addEventListener(
        event.replace(/^on/, ""),
        (e) => {
          const payload = {
            type: e.type,
            target: e.target && {
              value: e.target.value
            }
          };
          fetch("/callback", {
            method: "POST",
            headers: new Headers({
              "content-type": "application/json"
            }),
            body: JSON.stringify([this.sessionId, callbackId, payload])
          })
        }
      )
    )
  },
  RemoveHandler(id, event, callbackId) {
    nodes.get(id).removeEventListener(
      event.replace(/^on/, ""),
      this.nodes.get(callbackId),
    )
    this.nodes.delete(callbackId)
  }
}
