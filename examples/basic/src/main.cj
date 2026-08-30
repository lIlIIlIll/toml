// SPDX-License-Identifier: Apache-2.0
package toml_basic_example

import toml.*

main(): Int64 {
    let source = "title = \"demo\"\n[server]\nport = 8080\n"
    let config = Toml.parse(source).getOrThrow()
    println("title=${config["title"].asString().value}")
    println("port=${config["server"].asTable()["port"].asInteger().value}")

    let document = parseTomlDocument(source).getOrThrow()
    let portPath = TomlPath().withKey("server").withKey("port")
    let session = document.beginEdit()
    let _ = session.replaceValue(portPath, TomlInteger(9090)).getOrThrow()
    let edited = session.commit().getOrThrow()
    println("edited_port=${edited.semantic().getOrThrow()["server"].asTable()["port"].asInteger().value}")
    println("original_unchanged=${document.text() == source}")
    0
}
