const DEFAULT_ENDPOINT = "/.rdom";
const SESSION_ID_HEADER = "x-rdom-session-id";
const STREAM_MIME_TYPE = "x-rdom/json-stream";

customElements.define(
  "vdom-root",
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
  console.log(res.headers.get("content-type"));
  console.log(Object.fromEntries(res.headers.entries()));

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
        console.log(JSON.stringify(chunk))
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
          console.log("Applying", type, args);

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
    this.nodes.set(null, this.root);
  },
  CreateElement(id, type) {
    this.nodes.set(id, document.createElement(type));
  },
  InsertBefore(parentId, id, refId) {
    this.nodes
      .get(parentId)
      .insertBefore(this.nodes.get(id), refId && this.nodes.get(refId));
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
  SetAttribute(id, name, value) {
    if (name === "value") {
      this.nodes.get(id).value = value;
      return;
    }
    this.nodes.get(id).setAttribute(name, value);
  },
  RemoveAttribute(id, name) {
    this.nodes.get(id).removeAttribute(name);
  },
  CreateDocumentFragment(id) {
    this.nodes.set(id, document.createDocumentFragment());
  },
  SetCSSProperty(id, name, value) {
    this.nodes.get(id).style.setProperty(name, value);
  },
  RemoveCSSProperty(id, name) {
    this.nodes.get(id).style.removeProperty(name);
  },
  SetHandler(id, event, callbackId) {
    this.nodes.set(
      callbackId,
      this.nodes.get(id).addEventListener(event.replace(/^on/, ""), (e) => {
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
  RemoveHandler(id, event, callbackId) {
    this.nodes
      .get(id)
      ?.removeEventListener(
        event.replace(/^on/, ""),
        this.nodes.get(callbackId)
      );
    this.nodes.delete(callbackId);
  },
  Ping(time) {
    console.info("Ping", time);
    this.enqueue(["pong", time]);
  },
};
