import { useEffect, useMemo, useRef, useState } from "react";
import { invoke, isTauri } from "@tauri-apps/api/core";
import "./App.css";

interface Edition {
  id: string;
  revision: number;
  title: string;
  format: string;
  isbn13: string | null;
  release_date: string | null;
  contributors: { name: string; role: string }[];
  categories: string[];
}

function decode(source: string): Edition[] {
  const parsed: unknown = JSON.parse(source);
  if (!parsed || typeof parsed !== "object" || !("synthetic" in parsed) || parsed.synthetic !== true
    || !("editions" in parsed) || !Array.isArray(parsed.editions)) throw new Error("Invalid synthetic catalog.");
  return decodeRecords(parsed.editions);
}

function decodeRecords(records: unknown): Edition[] {
  if (!Array.isArray(records)) throw new Error("Missing editions array.");
  return records.map((row: unknown) => {
    if (!row || typeof row !== "object" || !("id" in row) || typeof row.id !== "string"
      || !("revision" in row) || !Number.isSafeInteger(row.revision) || typeof row.revision !== "number" || row.revision < 1
      || !("title" in row) || typeof row.title !== "string"
      || !("format" in row) || typeof row.format !== "string"
      || !("isbn13" in row) || (row.isbn13 !== null && typeof row.isbn13 !== "string")
      || !("release_date" in row) || (row.release_date !== null && typeof row.release_date !== "string")
      || !("contributors" in row) || !Array.isArray(row.contributors)
      || !("categories" in row) || !Array.isArray(row.categories)
      || !row.categories.every((value: unknown) => typeof value === "string")) {
      throw new Error("Invalid edition record.");
    }
    const contributors = row.contributors.map((credit: unknown) => {
      if (!credit || typeof credit !== "object" || !("name" in credit) || typeof credit.name !== "string"
        || !("role" in credit) || typeof credit.role !== "string") throw new Error("Invalid contributor.");
      return { name: credit.name, role: credit.role };
    });
    return { id: row.id, revision: row.revision, title: row.title, format: row.format, isbn13: row.isbn13,
      release_date: row.release_date, categories: row.categories, contributors };
  });
}

interface BackendConfig {
  provider: "postgrest" | "gateway";
  base_url: string;
  access_token: string;
  api_key: string | null;
}

function failureMessage(failure: unknown): string {
  if (failure && typeof failure === "object" && "message" in failure && typeof failure.message === "string") return failure.message;
  return String(failure);
}

async function loadFixture(native: boolean): Promise<Edition[]> {
  if (native) return decode(await invoke<string>("fixture"));
  const response = await fetch("/catalog.json");
  if (!response.ok) throw new Error("Generate fixtures with ruby script/fixtures.rb before starting the preview.");
  return decode(await response.text());
}

function App() {
  const [editions, setEditions] = useState<Edition[]>([]);
  const [query, setQuery] = useState("");
  const [page, setPage] = useState(0);
  const [message, setMessage] = useState("Loading synthetic records...");
  const [error, setError] = useState(false);
  const [busy, setBusy] = useState(true);
  const [config, setConfig] = useState<BackendConfig | null>(null);
  const [role, setRole] = useState("");
  const [editing, setEditing] = useState<Edition | null>(null);
  const [draft, setDraft] = useState("");
  const [editError, setEditError] = useState("");
  const [source, setSource] = useState<"fixture" | "backend" | "unavailable">("fixture");
  const searchRef = useRef<HTMLInputElement>(null);
  const titleRef = useRef<HTMLInputElement>(null);
  const editTrigger = useRef<HTMLButtonElement | null>(null);
  const native = import.meta.env.MODE === "native" && isTauri();
  useEffect(() => {
    let active = true;
    loadFixture(native).then((rows) => {
      if (!active) return;
      setEditions(rows);
      setMessage(`${rows.length} synthetic editions loaded. No backend connected.`);
    }).catch((failure: unknown) => {
      if (active) { setSource("unavailable"); setError(true); setMessage(String(failure)); }
    }).finally(() => { if (active) setBusy(false); });
    return () => { active = false; };
  }, [native]);
  useEffect(() => {
    if (editing) {
      titleRef.current?.focus();
      titleRef.current?.scrollIntoView({ block: "center" });
    }
  }, [editing]);
  function finishEditing() {
    setEditing(null);
    requestAnimationFrame(() => {
      (editTrigger.current?.isConnected ? editTrigger.current : searchRef.current)?.focus();
    });
  }

  const matches = useMemo(() => {
    const needle = query.trim().toLocaleLowerCase("en");
    return editions.filter((row) => [row.title, row.isbn13 ?? "", ...row.categories, ...row.contributors.map((credit) => credit.name)]
      .some((value) => value.toLocaleLowerCase("en").includes(needle)));
  }, [query, editions]);
  const pages = Math.max(1, Math.ceil(matches.length / 50));
  const currentPage = Math.min(page, pages - 1);
  async function action(command: string, format = "csv") {
    setBusy(true); setError(false);
    try {
      const result = await invoke<string>(command, { format });
      if (command === "read_cache") {
        setEditions(decode(result));
        setSource("fixture");
        setMessage("Decrypted synthetic cache. Its local timestamp is not verified membership.");
      } else setMessage(result);
    } catch (failure) { setError(true); setMessage(String(failure)); }
    finally { setBusy(false); }
  }
  async function connect(candidate: BackendConfig) {
    setBusy(true); setError(false); setEditing(null); setEditions([]); setSource("unavailable");
    try {
      const result = await invoke<{ editions: unknown; role: string }>("load_backend", { config: candidate });
      setEditions(decodeRecords(result.editions));
      setConfig(candidate); setRole(result.role); setPage(0); setSource("backend");
      setMessage(`Connected to ${candidate.provider} as ${result.role}. Online-only; these records are not cached.`);
    } catch (failure) {
      setConfig(null); setRole(""); setError(true); setMessage(failureMessage(failure));
    } finally { setBusy(false); }
  }
  async function disconnect() {
    setConfig(null); setRole(""); setEditing(null);
    setBusy(true); setError(false); setEditions([]); setSource("unavailable");
    try {
      setEditions(await loadFixture(native)); setSource("fixture"); setPage(0);
      setMessage("Disconnected. Synthetic catalog restored; test token discarded.");
    } catch (failure) { setError(true); setMessage(failureMessage(failure)); }
    finally { setBusy(false); }
  }
  async function saveTitle() {
    if (!editing || !config) return;
    setBusy(true); setEditError("");
    try {
      const result = await invoke<unknown>("save_backend_title", {
        config, id: editing.id, revision: editing.revision, title: draft,
      });
      const saved = decodeRecords([result])[0];
      setEditions((rows) => rows.map((row) => row.id === saved.id ? saved : row));
      finishEditing(); setMessage(`Title saved at revision ${saved.revision}.`); setError(false);
    } catch (failure) { setEditError(failureMessage(failure)); }
    finally { setBusy(false); }
  }
  return <main>
    <header><span>Bookalog / Tauri comparison</span><span>{native ? "Native runtime" : "Browser fixture preview"}</span></header>
    <h1>{busy && !editions.length ? "Loading catalog" : source === "unavailable" ? "Catalog unavailable" : config ? "Connected comparison catalog" : "Synthetic catalog"}</h1>
    <p className="intro">Feasibility tools, not the production interface. No sign-in or verified offline membership lease.</p>
    {config && <p className="source-status">{config.provider === "postgrest" ? "Supabase / PostgREST" : "Google Cloud gateway"}
      {" · "}{role}{" · "}Online-only. {role === "viewer" ? "Read-only access." : "Select a title to edit."}</p>}
    {native && <BackendConnection busy={busy} connected={config !== null} onConnect={connect} />}
    {config && <div className="actions">
      <button disabled={busy || editing !== null} onClick={() => connect(config)}>Reload backend</button>
      <button disabled={busy || editing !== null} onClick={disconnect}>Disconnect and restore fixture</button>
      {editing && <span>Cancel your draft before reloading or disconnecting.</span>}
    </div>}
    {editing && <form className="edit-title" onSubmit={(event) => { event.preventDefault(); void saveTitle(); }}>
      <h2>Edit title</h2>
      <p>Saving against revision {editing.revision}. A conflict keeps your draft here; copy it before canceling and reloading.</p>
      <label htmlFor="edit-title">Title</label>
      <input ref={titleRef} id="edit-title" value={draft} required maxLength={500} disabled={busy}
        onChange={(event) => setDraft(event.target.value)} />
      {editError && <p role="alert" className="error">{editError}</p>}
      <div className="actions">
        <button className="primary" disabled={busy || !draft.trim()} type="submit">Save title</button>
        <button disabled={busy} type="button" onClick={finishEditing}>Cancel edit</button>
      </div>
    </form>}
    <label htmlFor="search">Search title, ISBN, contributor, or category</label>
    <div className="search-control">
      <input ref={searchRef} id="search" type="search" value={query} onChange={(event) => { setQuery(event.target.value); setPage(0); }} />
      {query && <button onClick={() => { setQuery(""); setPage(0); searchRef.current?.focus(); }}>Clear search</button>}
    </div>
    <details className="comparison-tools">
      <summary>File exchange and test cache</summary>
      {!native && <p>These tools require the native app. This browser preview supports catalog browsing and search.</p>}
      {config && <p>Disconnect to use these tools with the synthetic fixture. Connected records are never cached or exported here.</p>}
      <div className="tool-groups">
        <section aria-labelledby="exchange-heading">
          <h2 id="exchange-heading">File exchange</h2>
          <p>CSV/XLSX: seven columns. Illustrative ONIX: identifiers, titles, and formats only. Preview does not import records.</p>
          <div className="actions">
            {[["preview_file", "Preview file", "csv"], ["export_file", "Export CSV", "csv"], ["export_file", "Export XLSX", "xlsx"],
              ["export_file", "Export illustrative ONIX", "xml"]]
              .map(([command, label, format]) => <button key={label} disabled={!native || busy || config !== null || !editions.length}
                onClick={() => action(command, format)}>{label}</button>)}
          </div>
        </section>
        <section aria-labelledby="cache-heading">
          <h2 id="cache-heading">Synthetic cache</h2>
          <p>Encrypted fixture only. Its local expiry does not prove offline membership.</p>
          <div className="actions">
            {[["save_cache", "Save test cache"], ["read_cache", "Read test cache"], ["clear_cache", "Clear test cache"]]
              .map(([command, label]) => <button key={command} disabled={!native || busy || config !== null || (command === "save_cache" && !editions.length)}
                onClick={() => action(command)}>{label}</button>)}
          </div>
        </section>
      </div>
    </details>
    <p role={error ? "alert" : "status"} className={error ? "error" : "status"}>{busy ? "Working..." : message}</p>
    <div className="results"><strong aria-live="polite">{matches.length.toLocaleString()} matching {matches.length === 1 ? "edition" : "editions"}</strong>
      <nav aria-label="Result pages">
        <button disabled={currentPage === 0} onClick={() => setPage(currentPage - 1)}>Previous</button>
        <span>Page {currentPage + 1} of {pages}</span>
        <button disabled={currentPage + 1 >= pages} onClick={() => setPage(currentPage + 1)}>Next</button>
      </nav>
    </div>
    <p id="table-help" className="table-help">Scroll the table horizontally to see ISBN and publication date.</p>
    <div className="table-scroll" tabIndex={0} role="region" aria-label="Catalog results" aria-describedby="table-help">
      <table><thead><tr><th scope="col">Title</th><th scope="col">Format</th><th scope="col">ISBN</th><th scope="col">Publication date</th></tr></thead>
        <tbody>{matches.slice(currentPage * 50, currentPage * 50 + 50).map((row) => <tr key={row.id}>
          <td>{config && role !== "viewer" ? <button className="title-button" aria-label={`Edit title: ${row.title}`} disabled={busy || editing !== null}
            onClick={(event) => { editTrigger.current = event.currentTarget; setEditing(row); setDraft(row.title); setEditError(""); }}>{row.title}</button> : row.title}</td>
          <td>{row.format}</td><td>{row.isbn13 ?? "No ISBN"}</td><td>{row.release_date ?? "Date unknown"}</td>
        </tr>)}</tbody></table>
      {!matches.length && <div className="empty-state">
        {busy ? <p>Loading catalog...</p> : source === "unavailable" ? <>
          <h2>No catalog loaded</h2><p>Resolve the connection error above, or return to the synthetic fixture.</p>
          <button onClick={disconnect}>Restore synthetic catalog</button>
        </> : <>
          <h2>{query ? "No matching editions" : "No editions in this catalog"}</h2>
          <p>{query ? "Try a title, ISBN, contributor, or category." : "Reload the backend or restore the synthetic fixture."}</p>
          {query && <button onClick={() => { setQuery(""); setPage(0); searchRef.current?.focus(); }}>Clear search</button>}
        </>}
      </div>}
    </div>
  </main>;
}

function BackendConnection({ busy, connected, onConnect }: {
  busy: boolean; connected: boolean; onConnect: (config: BackendConfig) => Promise<void>;
}) {
  const [provider, setProvider] = useState<BackendConfig["provider"]>("postgrest");
  const [url, setUrl] = useState("");
  const [token, setToken] = useState("");
  const [apiKey, setApiKey] = useState("");
  return <details className="connection">
    <summary>Test backend connection</summary>
    <p>Disposable comparison environments only. This is not Google sign-in.
      Tokens stay in memory and are discarded on disconnect or app exit.</p>
    <form onSubmit={(event) => {
      event.preventDefault();
      const candidate = { provider, base_url: url, access_token: token, api_key: apiKey || null };
      setToken(""); setApiKey("");
      void onConnect(candidate);
    }}>
      <fieldset disabled={busy || connected}>
        <legend>Connection details</legend>
        <label htmlFor="backend-provider">Backend</label>
        <select id="backend-provider" value={provider} onChange={(event) => {
          if (event.target.value === "postgrest" || event.target.value === "gateway") setProvider(event.target.value);
        }}><option value="postgrest">Supabase / PostgREST</option><option value="gateway">Google Cloud gateway</option></select>
        <label htmlFor="backend-url">API base URL (include /rest/v1 for hosted Supabase)</label>
        <input id="backend-url" type="url" required value={url} onChange={(event) => setUrl(event.target.value)} />
        <label htmlFor="backend-token">Test access token</label>
        <input id="backend-token" type="password" autoComplete="off" required value={token} onChange={(event) => setToken(event.target.value)} />
        <label htmlFor="backend-key">Supabase publishable key (not needed locally)</label>
        <input id="backend-key" type="password" autoComplete="off" value={apiKey} onChange={(event) => setApiKey(event.target.value)} />
        <div className="actions"><button className="primary" type="submit">Connect and load catalog</button></div>
      </fieldset>
    </form>
  </details>;
}
export default App;
