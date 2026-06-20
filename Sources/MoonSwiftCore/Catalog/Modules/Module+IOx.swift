// File: Sources/MoonSwiftCore/Catalog/Modules/Module+IOx.swift
// Folder: Sources/MoonSwiftCore/Catalog/Modules/
// Role: Catalog entry for luaswift.iox — file system and path utilities,
//       opt-in because sandboxed projects should not have file access by default.
//
//       Verified against: LuaSwift/Sources/LuaSwift/Modules/Swift/IOModule.swift
//       (Lua run block: luaswift.iox = { read_file, write_file, append_file,
//        exists, is_file, is_dir, list_dir, mkdir, remove, rename, stat,
//        path = { join, basename, dirname, extension, absolute, normalize } }).
//       Signatures sourced from IOModule.swift callback implementations and the
//       module-level Lua API doc comment.
//
//       The `path` sub-table functions are catalogued with the `path.` prefix
//       so consumers know they live inside the nested table.
//
//       Availability: .optIn — the user must declare `iox` in
//       `lint.extra_modules` in moonswift.toml.
//
// Upstream: CatalogTypes
// Downstream: LuaModuleCatalog.v0

extension CatalogModule {

    /// `luaswift.iox` — file system access and path utilities.
    static let iox = CatalogModule(
        tableName: "iox",
        functions: [
            // File operations
            // Source: IOModule.swift readFileCallback — args[0]=path
            CatalogFunction(
                name: "read_file",
                params: [
                    CatalogParam(name: "path", type: "string")
                ],
                returns: "string",
                doc:
                    "Read the entire contents of a file at path and return it as a string. Path must be within a configured allowed directory; throws on access violation or read error."
            ),
            // Source: IOModule.swift writeFileCallback — args[0]=path, args[1]=content
            CatalogFunction(
                name: "write_file",
                params: [
                    CatalogParam(name: "path", type: "string"),
                    CatalogParam(name: "content", type: "string"),
                ],
                returns: nil,
                doc:
                    "Write content to a file at path, creating or overwriting it. Path must be within an allowed directory."
            ),
            // Source: IOModule.swift appendFileCallback — args[0]=path, args[1]=content
            CatalogFunction(
                name: "append_file",
                params: [
                    CatalogParam(name: "path", type: "string"),
                    CatalogParam(name: "content", type: "string"),
                ],
                returns: nil,
                doc:
                    "Append content to a file at path. Creates the file if it does not exist. Path must be within an allowed directory."
            ),
            // Source: IOModule.swift existsCallback — args[0]=path
            CatalogFunction(
                name: "exists",
                params: [
                    CatalogParam(name: "path", type: "string")
                ],
                returns: "boolean",
                doc: "Return true if path exists (file or directory), false otherwise."
            ),
            // Source: IOModule.swift isFileCallback — args[0]=path
            CatalogFunction(
                name: "is_file",
                params: [
                    CatalogParam(name: "path", type: "string")
                ],
                returns: "boolean",
                doc: "Return true if path exists and is a regular file."
            ),
            // Source: IOModule.swift isDirCallback — args[0]=path
            CatalogFunction(
                name: "is_dir",
                params: [
                    CatalogParam(name: "path", type: "string")
                ],
                returns: "boolean",
                doc: "Return true if path exists and is a directory."
            ),
            // Source: IOModule.swift listDirCallback — args[0]=path
            CatalogFunction(
                name: "list_dir",
                params: [
                    CatalogParam(name: "path", type: "string")
                ],
                returns: "table",
                doc: "Return an array of entry names (not full paths) in the directory at path."
            ),
            // Source: IOModule.swift mkdirCallback — args[0]=path
            CatalogFunction(
                name: "mkdir",
                params: [
                    CatalogParam(name: "path", type: "string")
                ],
                returns: nil,
                doc: "Create the directory at path, including any missing parent directories (equivalent to mkdir -p)."
            ),
            // Source: IOModule.swift removeCallback — args[0]=path
            CatalogFunction(
                name: "remove",
                params: [
                    CatalogParam(name: "path", type: "string")
                ],
                returns: nil,
                doc:
                    "Remove the file or empty directory at path. Throws if the path does not exist or the directory is non-empty."
            ),
            // Source: IOModule.swift renameCallback — args[0]=old_path, args[1]=new_path
            CatalogFunction(
                name: "rename",
                params: [
                    CatalogParam(name: "old_path", type: "string"),
                    CatalogParam(name: "new_path", type: "string"),
                ],
                returns: nil,
                doc:
                    "Rename or move the file or directory from old_path to new_path. Both paths must be within allowed directories."
            ),
            // Source: IOModule.swift statCallback — args[0]=path
            // Returns {size, is_file, is_dir, modified, created} table
            CatalogFunction(
                name: "stat",
                params: [
                    CatalogParam(name: "path", type: "string")
                ],
                returns: "table",
                doc:
                    "Return a table with file metadata: {size=number, is_file=boolean, is_dir=boolean, modified=number, created=number}. Timestamps are Unix epoch seconds."
            ),
            // Path sub-table entries (iox.path.<name>)
            // Source: IOModule.swift pathJoinCallback — args=vararg strings
            CatalogFunction(
                name: "path.join",
                params: [
                    CatalogParam(name: "...", type: "string")
                ],
                returns: "string",
                doc: "Join path components with the platform separator and return the resulting path string."
            ),
            // Source: IOModule.swift pathBasenameCallback — args[0]=path
            CatalogFunction(
                name: "path.basename",
                params: [
                    CatalogParam(name: "path", type: "string")
                ],
                returns: "string",
                doc: "Return the final component of path (the filename, including extension)."
            ),
            // Source: IOModule.swift pathDirnameCallback — args[0]=path
            CatalogFunction(
                name: "path.dirname",
                params: [
                    CatalogParam(name: "path", type: "string")
                ],
                returns: "string",
                doc: "Return the directory portion of path (everything up to but not including the last separator)."
            ),
            // Source: IOModule.swift pathExtensionCallback — args[0]=path
            CatalogFunction(
                name: "path.extension",
                params: [
                    CatalogParam(name: "path", type: "string")
                ],
                returns: "string",
                doc: "Return the file extension of path without the leading dot, or an empty string if there is none."
            ),
            // Source: IOModule.swift pathAbsoluteCallback — args[0]=path
            CatalogFunction(
                name: "path.absolute",
                params: [
                    CatalogParam(name: "path", type: "string")
                ],
                returns: "string",
                doc: "Return the absolute form of path, resolving it relative to the current working directory."
            ),
            // Source: IOModule.swift pathNormalizeCallback — args[0]=path
            CatalogFunction(
                name: "path.normalize",
                params: [
                    CatalogParam(name: "path", type: "string")
                ],
                returns: "string",
                doc: "Normalize path by resolving . and .. components and collapsing redundant separators."
            ),
        ],
        availability: .optIn
    )
}
