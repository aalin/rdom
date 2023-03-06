const DEFAULT_ENDPOINT = "/.rdom"
const SESSION_ID_HEADER = "x-rdom-session-id"
const STREAM_MIME_TYPE = "x-rdom/json-stream"

customElements.define(
  "vdom-root",
  class VDOMRoot extends HTMLElement {
    constructor() {
      super();
      this.attachShadow({ mode: "open" })
    }

    async connectedCallback() {
      const endpoint = this.getAttribute("src") || DEFAULT_ENDPOINT

      const res = await fetch(endpoint, {
        method: "GET",
        mode: "cors",
        headers: new Headers({ "accept": STREAM_MIME_TYPE }),
        credentials: "same-origin"
      });

      if (!res.ok) {
        alert("Connection failed!")
        console.error(res);
        throw new Error("Res was not ok.");
      }

      const contentType = res.headers.get("content-type");

      if (contentType !== STREAM_MIME_TYPE) {
        alert(`Unexpected content type: ${contentType}`)
        console.error(res);
        throw new Error(`Unexpected content type: ${contentType}`)
      }

      const patcher = new Patcher(this.shadowRoot, endpoint)

      res.body
        .pipeThrough(new TextDecoderStream())
        .pipeThrough(initJSONDecoder())
        .pipeTo(patcher.getWriter())
    }
  }
);

function initJSONDecoder() {
  // This function is based on https://rob-blackbourn.medium.com/beyond-eventsource-streaming-fetch-with-readablestream-5765c7de21a1#6c5e
  return new TransformStream({
    start(controller) {
      controller.buf = ''
      controller.pos = 0
    },

    transform(chunk, controller) {
      controller.buf += chunk

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

class Patcher {
  constructor(root, endpoint) {
    this.endpoint = endpoint
    this.sessionId = null
    this.root = root
    this.nodes = new Map()
  }

  apply(patch) {
    const [type, ...args] = patch
    const patchFn = PatchFunctions[type]

    if (patchFn) {
      console.log('Applying', type, args)
      try {
        patchFn.apply(this, args)
      } catch (e) {
        console.error(e)
      }
      return
    }

    console.error("Patch not implemented:", type)
  }

  getWriter() {
    return new WritableStream({
      write: this.apply.bind(this)
    })
  }
}

const PatchFunctions = {
  CreateRoot(sessionId) {
    this.sessionId = sessionId
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
    const child = this.nodes.get(id)
    if (!child) return

    const parent = this.nodes.get(parentId)
    if (!parent) return

    if (child.parent == parent) {
      parent.removeChild(child)
    }
  },
  RemoveNode(id) {
    const node = this.nodes.get(id)
    if (!node) return
    if (node.remove) {
      node.remove()
    }
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
          fetch(this.endpoint, {
            method: "PUT",
            headers: new Headers({
              "content-type": "application/json"
            }),
            mode: "cors",
            body: JSON.stringify([this.sessionId, callbackId, payload]),
          })
        }
      )
    )
  },
  RemoveHandler(id, event, callbackId) {
    this.nodes.get(id).removeEventListener(
      event.replace(/^on/, ""),
      this.nodes.get(callbackId),
    )
    this.nodes.delete(callbackId)
  },
  Ping(time) {
    console.info("Ping", time)
  }
}
