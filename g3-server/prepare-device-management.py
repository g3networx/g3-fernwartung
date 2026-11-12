"""Wire device management into a staged copy of the OpsLinX portal."""

import argparse
import ast
from pathlib import Path
import shutil


def patch_application(source):
    module = ast.parse(source)
    installers = {"bootstrap_client.install"}
    for statement in module.body:
        if isinstance(statement, ast.ImportFrom) and statement.module == "bootstrap_client":
            installers.update(name.asname or name.name for name in statement.names if name.name == "install")
    candidates = [
        statement for statement in module.body
        if isinstance(statement, ast.Expr) and isinstance(statement.value, ast.Call)
        and ast.unparse(statement.value.func) in installers
        and len(statement.value.args) == 2 and not statement.value.keywords
    ]
    if len(candidates) != 1:
        raise ValueError("Expected one top-level bootstrap_client.install call")
    if "device_management.install(" in source:
        return source
    statement = candidates[0]
    app, portal = (ast.unparse(arg) for arg in statement.value.args)
    lines = source.splitlines(keepends=True)
    lines[statement.end_lineno:statement.end_lineno] = [
        "import device_management\n",
        f"device_management.install({app}, {portal})\n",
    ]
    return "".join(lines)


def patch_bootstrap(source):
    original = "   result['registered']=True\n   return result\n"
    replacement = (
        "   result['registered']=True\n"
        "   management=app.config.get('DEVICE_MANAGEMENT_BOOTSTRAP_RESPONSE')\n"
        "   return management(data,d['id'],rid,pk,result) if management else result\n"
    )
    if replacement in source:
        return source
    if source.count(original) != 1:
        raise ValueError("Expected one authenticated credential-policy response")
    return source.replace(original, replacement)


def patch_device_list(source):
    anchor = '<a href="/devices/{{ d.id }}/edit">Gerät bearbeiten</a>'
    link = (
        "{% if config.get('DEVICE_MANAGEMENT_ENABLED') and g.user and g.user.role == 'admin' %}"
        '<a href="{{ url_for(\'device_management.manage\', did=d.id) }}">Geräteverwaltung</a>'
        "{% endif %}"
    )
    if link in source:
        return source
    if source.count(anchor) != 1:
        raise ValueError("Expected one device edit link in templates/index.html")
    return source.replace(anchor, anchor + link)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("staged_portal", type=Path)
    options = parser.parse_args()
    target = options.staged_portal.resolve(strict=True)
    if target == Path("/opt/rustdesk-addressbook").resolve():
        parser.error("Supply a staging copy of the portal")
    edits = {
        "app.py": patch_application,
        "bootstrap_client.py": patch_bootstrap,
    }
    updates = {}
    for name, patch in edits.items():
        path = target / name
        if path.is_symlink():
            parser.error(f"Staging file must be a regular file: {name}")
        updated = patch(path.read_text(encoding="utf-8"))
        compile(updated, str(path), "exec")
        updates[path] = updated
    templates = target / "templates"
    if templates.is_symlink() or not templates.is_dir():
        parser.error("Expected a regular templates directory in the staging copy")
    index = templates / "index.html"
    if index.is_symlink():
        parser.error("Staging template must be a regular file: index.html")
    updates[index] = patch_device_list(index.read_text(encoding="utf-8"))
    for path, updated in updates.items():
        path.write_text(updated, encoding="utf-8")
    source = Path(__file__).resolve().parent
    shutil.copyfile(source / "device_management.py", target / "device_management.py")
    shutil.copyfile(source / "templates/device_management.html", templates / "device_management.html")


if __name__ == "__main__":
    main()
