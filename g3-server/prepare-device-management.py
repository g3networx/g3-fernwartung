"""Wire device management into a staged copy of the OpsLinX portal."""

import argparse
import ast
from pathlib import Path
import shutil


def patch_application(source):
    module = ast.parse(source)
    candidates = [
        statement for statement in module.body
        if isinstance(statement, ast.Expr) and isinstance(statement.value, ast.Call)
        and isinstance(statement.value.func, ast.Attribute)
        and ast.unparse(statement.value.func) == "bootstrap_client.install"
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
    for path, updated in updates.items():
        path.write_text(updated, encoding="utf-8")
    source = Path(__file__).resolve().parent
    shutil.copyfile(source / "device_management.py", target / "device_management.py")
    shutil.copyfile(source / "templates/device_management.html", templates / "device_management.html")


if __name__ == "__main__":
    main()
