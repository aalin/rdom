const ELEMENT_NAME = "rdom-embed"
const DEFAULT_ENDPOINT = "/.rdom";
const SESSION_ID_HEADER = "x-rdom-session-id";
const STREAM_MIME_TYPE = "x-rdom/json-stream";
const DISCONNECTED_STATE = "--disconnected"

customElements.define(
  ELEMENT_NAME,
  class VDOMRoot extends HTMLElement {
    constructor() {
      super();
      this.attachShadow({ mode: "open" });
      this._internals = this.attachInternals();
      this._setConnectedState(false);

      const styles = new CSSStyleSheet();
      styles.replace(":host { display: flow-root; }")
      this.shadowRoot.adoptedStyleSheets = [styles]
    }

    async connectedCallback() {
      try {
        const endpoint = this.getAttribute("src") || DEFAULT_ENDPOINT;
        const res = await connect(endpoint);

        const output = initCallbackStream(
          endpoint,
          getSessionIdHeader(res),
        );

        this._setConnectedState(true)

        await res.body
          .pipeThrough(new TextDecoderStream())
          .pipeThrough(new JSONDecoderStream())
          .pipeThrough(new PatchStream(endpoint, this.shadowRoot))
          .pipeThrough(new JSONEncoderStream())
          .pipeThrough(new TextEncoderStream())
          .pipeTo(output)
      } finally {
        console.error('🔴 Disconnected!')
        this._setConnectedState(false)
      }
    }

    _setConnectedState(isConnected) {
      if (isConnected) {
        this._internals.states?.delete(DISCONNECTED_STATE)
      } else {
        this._internals.states?.add(DISCONNECTED_STATE)
      }
    }
  }
);

function getSessionIdHeader(res) {
  const sessionId = res.headers.get(SESSION_ID_HEADER);
  if (sessionId) return sessionId
  throw new Error(`Could not read header: ${SESSION_ID_HEADER}`);
}

async function connect(endpoint) {
  console.info('🟡 Connecting to', endpoint)

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

  console.info('🟢 Connected to', endpoint)

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
        controller.enqueue(JSON.stringify(chunk) + "\n")
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

class RAFQueue {
  constructor(onFlush) {
    this.onFlush = onFlush
    this.queue = []
    this.raf = null
  }

  enqueue(msg) {
    this.queue.push(msg)
    this.raf ||= requestAnimationFrame(() => this.flush())
  }

  flush() {
    this.raf = null
    const queue = this.queue;
    if (queue.length === 0) return
    this.queue = [];
    this.onFlush(queue)
  }
}

class PatchStream extends TransformStream {
  constructor(endpoint, root) {
    super({
      start(controller) {
        controller.endpoint = endpoint;
        controller.root = root;
        controller.nodes = new Map();

        controller.rafQueue = new RAFQueue((patches) => {
          console.debug('Applying', patches.length, 'patches');
          console.time('patch');

          for (const patch of patches) {
            const [type, ...args] = patch;
            const patchFn = PatchFunctions[type];

            if (!patchFn) {
              console.error("Patch not implemented:", type);
              continue
            }

            try {
              patchFn.apply(controller, args);
            } catch (e) {
              console.error(e);
            }
          }

          console.timeEnd('patch');
        });
      },
      transform(patch, controller) {
        controller.rafQueue.enqueue(patch);
      },
      flush(controller) {},
    })
  }
}

const PatchFunctions = {
  CreateRoot() {
    const root = document.createElement('rdom-root');
    this.nodes.set(null, root);
    this.root.appendChild(root);
  },
  DestroyRoot() {
    const root = this.nodes.get(null);
    if (!root) return;
    this.nodes.delete(null);
    root.remove();
  },
  CreateElement(id, type) {
    const CustomElement = customElements.get(type);
    this.nodes.set(id, new CustomElement())
  },
  InsertBefore(parentId, id, refId) {
    const parent = this.nodes.get(parentId);
    const child = this.nodes.get(id);
    const ref = refId && this.nodes.get(refId);
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
  DefineCustomElement(name, template, css) {
    RDOMElement.define(name, template, css)
  },
  AssignSlot(id, name, ids) {
    const node = this.nodes.get(id);
    node?.assignSlot(
      name,
      ids.map((id) => this.nodes.get(id)).filter(Boolean)
    )
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
    const parent = this.nodes.get(parentId);
    if (!parent) return
    const node = parent.shadowRoot?.getElementById(refId);
    if (!node) return

    if (node instanceof HTMLInputElement) {
      switch (name) {
        case "value": {
          node.value = value;
          break;
        }
        case "checked": {
          node.checked = true;
          break;
        }
        case "indeterminate": {
          node.indeterminate = true;
          break;
        }
      }
    }

    if (name === "initial-value") {
      name = "value";
    } else {
      name = name.replaceAll("_", "");
    }

    node.setAttribute(name, value);
  },
  RemoveAttribute(parentId, refId, name) {
    const parent = this.nodes.get(parentId);
    if (!parent) return
    const node = parent.shadowRoot?.getElementById(refId);
    node?.removeAttribute(name);
  },
  CreateDocumentFragment(id) {
    this.nodes.set(id, document.createDocumentFragment());
  },
  SetCSSProperty(parentId, refId, name, value) {
    const parent = this.nodes.get(parentId)
    if (!parent) return
    const node = parent.shadowRoot.getElementById(refId);
    if (!node) return
    node.style.setProperty(name, value);
  },
  RemoveCSSProperty(parentId, refId, name) {
    const parent = this.nodes.get(parentId)
    if (!parent) return
    const node = parent.shadowRoot.getElementById(refId);
    if (!node) return
    node.style.removeProperty(name);
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

class RDOMElement extends HTMLElement {
  static template = null;
  static stylesheet = null;
  static styles = createCustomElementStyleSheet();

  static define(name, html, stylesheet) {
    if (customElements.get(name)) {
      return
    }

    customElements.define(
      name,
      class extends RDOMElement {
        static template = createTemplate(html)
        static stylesheet = stylesheet
      }
    )
  }

  connectedCallback() {
    this.attachShadow({
      mode: "open",
      slotAssignment: "manual",
    });

    const { template, stylesheet, styles } = this.constructor;

    this.shadowRoot.appendChild(template.content.cloneNode(true));
    this.shadowRoot.adoptedStyleSheets = [styles];
    importAndAdoptStyleSheet(this.shadowRoot, stylesheet)
  }

  assignSlot(name, nodes) {
    const slot = this.shadowRoot.getElementById(name)
    if (!slot) {
      throw new Error(`No slot with id ${id}`)
    }
    slot.assign(...nodes);
  }
}

async function importAndAdoptStyleSheet(shadow, path) {
  if (!path) return

  const mod = await import(`/.rdom/${path}`, {
    assert: { type: 'css' }
  })

  shadow.adoptedStyleSheets.push(mod.default)
}

function createCustomElementStyleSheet() {
  const styles = new CSSStyleSheet();
  styles.replace(":host { display: contents; }")
  return styles;
}

function createTemplate(html) {
  const template = document.createElement("template");
  template.innerHTML = html
  return template
}
