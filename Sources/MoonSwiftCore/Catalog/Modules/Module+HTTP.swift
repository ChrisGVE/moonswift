// File: Sources/MoonSwiftCore/Catalog/Modules/Module+HTTP.swift
// Folder: Sources/MoonSwiftCore/Catalog/Modules/
// Role: Catalog entry for luaswift.http — HTTP client (GET, POST, PUT, PATCH,
//       DELETE, HEAD, OPTIONS, and the generic request function).
//
//       Verified against: LuaSwift/Sources/LuaSwift/Modules/Swift/HTTPModule.swift
//       (Lua run block: luaswift.http = { get, post, put, patch, delete, head,
//        options, request }).
//       Signatures sourced from HTTPModule.swift module-level Lua API doc comment.
//       All method functions share the same (url, options?) signature; request()
//       adds method as a first argument.
//       options table keys: headers (table), body (string), json (table),
//         follow_redirects (boolean), timeout (number), max_response_size (number).
//       Response object fields: status (number), headers (table), body (string),
//         ok (boolean), json() (function).
//
//       Availability: .optIn — network access must be explicitly requested by the
//       user via `lint.extra_modules = ["http"]` in moonswift.toml.
//
// Upstream: CatalogTypes
// Downstream: LuaModuleCatalog.v0

extension CatalogModule {

    /// `luaswift.http` — HTTP client methods.
    static let http = CatalogModule(
        tableName: "http",
        functions: [
            // Source: HTTPModule.swift Lua run block — http.get = function(url, options?)
            CatalogFunction(
                name: "get",
                params: [
                    CatalogParam(name: "url", type: "string"),
                    CatalogParam(name: "options", type: "table", isOptional: true),
                ],
                returns: "table",
                doc:
                    "Send an HTTP GET request. Returns a response table {status, headers, body, ok, json()}. options: {headers={}, follow_redirects=true, timeout=30, max_response_size=10485760}."
            ),
            // Source: HTTPModule.swift Lua run block — http.post = function(url, options?)
            CatalogFunction(
                name: "post",
                params: [
                    CatalogParam(name: "url", type: "string"),
                    CatalogParam(name: "options", type: "table", isOptional: true),
                ],
                returns: "table",
                doc:
                    "Send an HTTP POST request. options accepts {headers={}, body=string, json=table, follow_redirects, timeout}. When json= is set the body is auto-encoded and Content-Type set to application/json."
            ),
            // Source: HTTPModule.swift Lua run block — http.put = function(url, options?)
            CatalogFunction(
                name: "put",
                params: [
                    CatalogParam(name: "url", type: "string"),
                    CatalogParam(name: "options", type: "table", isOptional: true),
                ],
                returns: "table",
                doc: "Send an HTTP PUT request. Same options as http.post."
            ),
            // Source: HTTPModule.swift Lua run block — http.patch = function(url, options?)
            CatalogFunction(
                name: "patch",
                params: [
                    CatalogParam(name: "url", type: "string"),
                    CatalogParam(name: "options", type: "table", isOptional: true),
                ],
                returns: "table",
                doc: "Send an HTTP PATCH request. Same options as http.post."
            ),
            // Source: HTTPModule.swift Lua run block — http.delete = function(url, options?)
            CatalogFunction(
                name: "delete",
                params: [
                    CatalogParam(name: "url", type: "string"),
                    CatalogParam(name: "options", type: "table", isOptional: true),
                ],
                returns: "table",
                doc: "Send an HTTP DELETE request. Same options as http.get."
            ),
            // Source: HTTPModule.swift Lua run block — http.head = function(url, options?)
            CatalogFunction(
                name: "head",
                params: [
                    CatalogParam(name: "url", type: "string"),
                    CatalogParam(name: "options", type: "table", isOptional: true),
                ],
                returns: "table",
                doc: "Send an HTTP HEAD request. Response body is empty; status and headers are returned."
            ),
            // Source: HTTPModule.swift Lua run block — http.options = function(url, options?)
            CatalogFunction(
                name: "options",
                params: [
                    CatalogParam(name: "url", type: "string"),
                    CatalogParam(name: "options", type: "table", isOptional: true),
                ],
                returns: "table",
                doc: "Send an HTTP OPTIONS request. Returns allowed methods in the Allow response header."
            ),
            // Source: HTTPModule.swift Lua run block — http.request = function(method, url, options?)
            // Generic request; all method functions are thin wrappers around this.
            CatalogFunction(
                name: "request",
                params: [
                    CatalogParam(name: "method", type: "string"),
                    CatalogParam(name: "url", type: "string"),
                    CatalogParam(name: "options", type: "table", isOptional: true),
                ],
                returns: "table",
                doc:
                    "Send an HTTP request with an arbitrary method string. All convenience functions (get, post, …) are thin wrappers around this. Same options table as http.get/post."
            ),
        ],
        availability: .optIn
    )
}
