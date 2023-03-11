const ELEMENT_NAME = "rdom-embed"
const DEFAULT_ENDPOINT = "/.rdom";
const SESSION_ID_HEADER = "x-rdom-session-id";
const STREAM_MIME_TYPE = "x-rdom/json-stream";

customElements.define(
  ELEMENT_NAME,
  class VDOMRoot extends HTMLElement {
    constructor() {
      super();
      this.attachShadow({ mode: "open" });
    }

    async connectedCallback() {
      const endpoint = this.getAttribute("src") || DEFAULT_ENDPOINT;
      const res = await connect(endpoint);

      const output = initCallbackStream(
        endpoint,
        getSessionIdHeader(res),
      );

      res.body
        .pipeThrough(new TextDecoderStream())
        .pipeThrough(new JSONDecoderStream())
        .pipeThrough(new PatchStream(endpoint, this.shadowRoot))
        .pipeThrough(new JSONEncoderStream())
        .pipeThrough(new TextEncoderStream())
        .pipeTo(output);
    }
  }
);

function getSessionIdHeader(res) {
  const sessionId = res.headers.get(SESSION_ID_HEADER);
  if (sessionId) return sessionId
  throw new Error(`Could not read header: ${SESSION_ID_HEADER}`);
}

async function connect(endpoint) {
  const res = await fetch(endpoint, {
    method: "GET",
    mode: "cors",
    headers: new Headers({ accept: STREAM_MIME_TYPE }),
  });

  if (!res.ok) {
    alert("Connection failed!");
    console.error(res);
    throw new Error("Res was not ok.");
  }

  const contentType = res.headers.get("content-type");

  if (contentType !== STREAM_MIME_TYPE) {
    alert(`Unexpected content type: ${contentType}`);
    console.error(res);
    throw new Error(`Unexpected content type: ${contentType}`);
  }

  return res;
}

class JSONDecoderStream extends TransformStream {
  constructor() {
    // This transformer is based on this code:
    // https://rob-blackbourn.medium.com/beyond-eventsource-streaming-fetch-with-readablestream-5765c7de21a1#6c5e
    super({
      start(controller) {
        controller.buf = "";
        controller.pos = 0;
      },

      transform(chunk, controller) {
        controller.buf += chunk;

        while (controller.pos < controller.buf.length) {
          if (controller.buf[controller.pos] === "\n") {
            const line = controller.buf.substring(0, controller.pos);
            controller.enqueue(JSON.parse(line));
            controller.buf = controller.buf.substring(controller.pos + 1);
            controller.pos = 0;
          } else {
            controller.pos++;
          }
        }
      },
    })
  }
}

class JSONEncoderStream extends TransformStream {
  constructor() {
    super({
      transform(chunk, controller) {
        const transformed = JSON.stringify(chunk)
        console.log("Sending", transformed)
        controller.enqueue(transformed + "\n")
      }
    })
  }
}

const supportsRequestStreams = (() => {
  // https://developer.chrome.com/articles/fetch-streaming-requests/#feature-detection
  let duplexAccessed = false;

  const hasContentType = new Request("", {
    body: new ReadableStream(),
    method: "POST",
    get duplex() {
      duplexAccessed = true;
      return "half";
    },
  }).headers.has("Content-Type");

  return duplexAccessed && !hasContentType;
})();

function initCallbackStream(endpoint, sessionId) {
  if (!supportsRequestStreams) {
    return initCallbackStreamFetchFallback(endpoint, sessionId);
  }

  const { readable, writable } = new TransformStream();

  fetch(endpoint, {
    method: "POST",
    headers: {
      "content-type": STREAM_MIME_TYPE,
      [SESSION_ID_HEADER]: sessionId,
    },
    duplex: "half",
    mode: "cors",
    body: readable,
  });

  return writable;
}

function initCallbackStreamFetchFallback(endpoint, sessionId) {
  return new WritableStream({
    write(body, controller) {
      fetch(endpoint, {
        method: "POST",
        headers: new Headers({
          "content-type": "application/json",
          [SESSION_ID_HEADER]: sessionId,
        }),
        mode: "cors",
        body: body,
      });
    },
  });
}

class PatchStream extends TransformStream {
  constructor(endpoint, root) {
    super({
      start(controller) {
        controller.endpoint = endpoint;
        controller.root = root;
        controller.nodes = new Map();
      },
      transform(patch, controller) {
        const [type, ...args] = patch;
        const patchFn = PatchFunctions[type];

        if (patchFn) {
          console.debug("Applying", type, args);

          try {
            patchFn.apply(controller, args);
          } catch (e) {
            console.error(e);
          }
          return;
        }

        console.error("Patch not implemented:", type);
      },
      flush(controller) {},
    })
  }
}

const PatchFunctions = {
  CreateRoot() {
    // this.nodes.set(null, this.root)
    const root = document.createElement('rdom-root');
    this.nodes.set(null, root);
    this.root.appendChild(root);
    console.warn("ROOT", this.root)
  },
  DestroyRoot() {
    // const root = this.nodes.get(null);
    // if (!root) return;
    // this.nodes.delete(null);
    // root.remove();
  },
  CreateElement(id, type) {
    const elem = new (customElements.get(type))
    // const elem = document.createElement(type);
    elem.setAttribute("id", id)
    this.nodes.set(id, elem)
  },
  InsertBefore(parentId, id, refId) {
    const parent = this.nodes.get(parentId);
    //
    // if (!parent) {
    //   console.error("Could not find parent with id", parentId)
    //   console.warn("Could not find parent with id", parentId)
    //   console.log("Could not find parent with id", parentId)
    //   alert("Could not find parent with id " + parentId)
    //   return
    // }

    const child = this.nodes.get(id);
    const ref = refId && this.nodes.get(refId);

    console.info("Inserting", child.textContent, "before", ref?.textContent);

    parent.insertBefore(child, ref);
  },
  RemoveChild(parentId, id) {
    const child = this.nodes.get(id);
    if (!child) return;

    const parent = this.nodes.get(parentId);
    if (!parent) return;

    if (child.parent == parent) {
      parent.removeChild(child);
    }
  },
  RemoveNode(id) {
    const node = this.nodes.get(id);
    if (!node) return;
    if (node.remove) {
      node.remove();
    }
    this.nodes.delete(id);
  },
  DefineCustomElement(name, template) {
    defineCustomElement(name, template)
  },
  CreateChildren(parentId, id) {
    const parent = this.nodes.get(parentId);

    if (!parent) {
      throw new Error(`Could not find parent with id`, parentId)
    }

    const node = document.createElement("rdom-children")

    const shadow = node.attachShadow({
      mode: "open",
      slotAssignment: "manual"
    })

    const slot = document.createElement("slot")
    slot.setAttribute("id", id)

    shadow.append(slot);
    parent.append(node);

    this.nodes.set(id, node)
    this.nodes.set(`${id}-slot`, slot)
  },
  RemoveChildren(id) {
    this.nodes.get(id)?.remove();
    this.nodes.delete(id)
    this.nodes.get(`${id}-slot`)?.remove();
    this.nodes.delete(`${id}-slot`)
  },
  ReorderChildren(id, ids) {
    const node = this.nodes.get(`${id}`);
    const slot = this.slots.get(`${id}-slot`);
    if (!slot) return
    const nodes = ids.map((id) => this.nodes.get(id)).filter(Boolean);
    console.log(slot, nodes.map((slot) => slot))
    slot.assign.apply(slot, nodes)
    console.log(slot)
  },
  AssignSlot(id, name, ids) {
    const node = this.nodes.get(id);
    if (!node) return
    if (!node.shadowRoot) {
      console.log("No shadow root", node)
      return
    }
    const slot = node.shadowRoot.getElementById(name)
    if (!slot) {
      console.log("No slot with id", name)
      return
    }
    const nodes = ids.map((id) => this.nodes.get(id)).filter(Boolean);
    slot.assign(...nodes);
  },
  CreateTextNode(id, content) {
    this.nodes.set(id, document.createTextNode(content));
  },
  SetTextContent(id, content) {
    this.nodes.get(id).textContent = content;
  },
  ReplaceData(id, offset, count, data) {
    this.nodes.get(id).replaceData(offset, count, data);
  },
  InsertData(id, offset, data) {
    this.nodes.get(id).insertData(offset, data);
  },
  DeleteData(id, offset, count) {
    this.nodes.get(id).deleteData(offset, count);
  },
  SetAttribute(parentId, refId, name, value) {
    const node =
      parentId
      ? this.nodes.get(parentId)?.shadowRoot?.getElementById(refId)
      : this.nodes.get(refId);

    if (!node) return

    if (name === "value") {
      node.value = value;
    } else {
      node.setAttribute(name, value);
    }
  },
  RemoveAttribute(parentId, refId, name) {
    const parent = this.nodes.get(parentId)
    if (!parent) return
    const node = parent.shadowRoot?.getElementById(refId)
    node?.removeAttribute(name);
  },
  CreateDocumentFragment(id) {
    this.nodes.set(id, document.createDocumentFragment());
  },
  SetCSSProperty(id, name, value) {
    this.nodes.get(id).style.setProperty(name, value);
  },
  RemoveCSSProperty(id, name) {
    this.nodes.get(id)?.style?.removeProperty(name);
  },
  SetHandler(parentId, refId, event, callbackId) {
    const parent = this.nodes.get(parentId)
    const elem = parent.shadowRoot.getElementById(refId);

    this.nodes.set(
      callbackId,
      elem.addEventListener(event.replace(/^on/, ""), (e) => {
        const payload = {
          type: e.type,
          target: e.target && {
            value: e.target.value,
          },
        };

        this.enqueue(["callback", callbackId, payload]);
      })
    );
  },
  RemoveHandler(parentId, refId, event, callbackId) {
    const parent = this.nodes.get(parentId)
    if (!parent) return
    const elem = parent.shadowRoot?.getElementById(refId);

    elem?.removeEventListener(
      event.replace(/^on/, ""),
      this.nodes.get(callbackId)
    );
    this.nodes.delete(callbackId);
  },
  Ping(time) {
    this.enqueue(["pong", time]);
  },
};

function createTemplate(html) {
  const template = document.createElement("template");
  template.innerHTML = html;
  return template
}

function defineCustomElement(name, html) {
  const template = createTemplate(html)

  customElements.define(
    name,
    class extends HTMLElement {
      connectedCallback() {
        this.attachShadow({
          mode: "open",
          slotAssignment: "manual",
        });

        this.shadowRoot.appendChild(template.content.cloneNode(true));
      }
    }
  )
}
