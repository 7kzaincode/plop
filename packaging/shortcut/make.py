"""Builds plop's "Send to plop" Shortcut: from the share sheet (or, run on
its own, the clipboard) it posts each item to a shelf's web page, text as
text and anything else as a file. Run on a Mac, which signs it:

    python3 packaging/shortcut/make.py packages/core/lib/src/shortcut.g.dart

The web shelf serves it (web_host.dart), so a phone gets it from plop
itself, internet or not. A path ending .shortcut writes the file instead.
"""
import base64, plistlib, subprocess, sys, tempfile, textwrap, uuid, os

OBJ = "￼"


def uid():
    return str(uuid.uuid4()).upper()


def out(u, name):
    return {"Type": "ActionOutput", "OutputUUID": u, "OutputName": name}


REPEAT_ITEM = {"Type": "Variable", "VariableName": "Repeat Item"}


def var(v):
    return {"Value": v, "WFSerializationType": "WFTextTokenAttachment"}


def text(*parts):
    """A text field of plain strings and variables."""
    s, att = "", {}
    for p in parts:
        if isinstance(p, str):
            s += p
        else:
            at = len(s.encode("utf-16-le")) // 2
            att["{%d, 1}" % at] = p
            s += OBJ
    return {"Value": {"string": s, "attachmentsByRange": att},
            "WFSerializationType": "WFTextTokenString"}


def act(ident, **params):
    return {"WFWorkflowActionIdentifier": "is.workflow.actions." + ident,
            "WFWorkflowActionParameters": params}


def post(host, path, body, *query):
    return act(
        "downloadurl",
        UUID=uid(),
        WFURL=text("http://", host, path, *query),
        WFHTTPMethod="POST",
        WFHTTPBodyType="File",
        WFRequestVariable=var(body),
        WFHTTPHeaders={
            "Value": {"WFDictionaryFieldValueItems": [{
                "WFItemType": 0,
                "WFKey": text("x-plop-web"),
                "WFValue": text("1"),
            }]},
            "WFSerializationType": "WFDictionaryFieldValue",
        },
        ShowHeaders=True,
    )


def build():
    host_u, kind_u, match_u, str_u, name_u, ext_u, full_u, trim_u, enc_u = (
        uid() for _ in range(9))
    host = out(host_u, "Text")
    loop, branch = uid(), uid()
    actions = [
        # The shelf's address, asked once when the Shortcut is added.
        act("gettext", UUID=host_u, WFTextActionText="plop.local:7567"),
        act("repeat.each", GroupingIdentifier=loop, WFControlFlowMode=0,
            WFInput=var({"Type": "ExtensionInput"})),
        act("getitemtype", UUID=kind_u, WFInput=var(REPEAT_ITEM)),
        act("text.match", UUID=match_u, WFMatchTextPattern="^(Text|Rich Text|URL)$",
            WFMatchTextCaseSensitive=False, text=text(out(kind_u, "Type"))),
        act("conditional", GroupingIdentifier=branch, WFControlFlowMode=0,
            WFCondition=100, WFInput={"Type": "Variable",
                                      "Variable": var(out(match_u, "Matches"))}),
        act("gettext", UUID=str_u, WFTextActionText=text(REPEAT_ITEM)),
        post(host, "/web/text", out(str_u, "Text")),
        act("conditional", GroupingIdentifier=branch, WFControlFlowMode=1),
        act("getitemname", UUID=name_u, WFInput=var(REPEAT_ITEM)),
        # Shortcuts' names leave the extension off: put it back, or drop
        # the dot when there is none.
        act("properties.files", UUID=ext_u, WFInput=var(REPEAT_ITEM),
            WFContentItemPropertyName="File Extension"),
        act("gettext", UUID=full_u, WFTextActionText=text(
            out(name_u, "Name"), ".", out(ext_u, "File Extension"))),
        act("text.replace", UUID=trim_u, WFInput=text(out(full_u, "Text")),
            WFReplaceTextFind=r"\.$", WFReplaceTextReplace="",
            WFReplaceTextRegularExpression=True),
        act("urlencode", UUID=enc_u,
            WFInput=text(out(trim_u, "Updated Text"))),
        post(host, "/web/items?name=", REPEAT_ITEM, out(enc_u, "URL Encoded Text")),
        act("conditional", GroupingIdentifier=branch, WFControlFlowMode=2),
        act("repeat.each", GroupingIdentifier=loop, WFControlFlowMode=2),
    ]
    return {
        "WFWorkflowMinimumClientVersion": 900,
        "WFWorkflowMinimumClientVersionString": "900",
        "WFWorkflowClientVersion": "2302.0.4",
        "WFWorkflowIcon": {"WFWorkflowIconStartColor": 255,  # black
                           "WFWorkflowIconGlyphNumber": 59511},
        "WFWorkflowTypes": ["ActionExtension"],
        "WFWorkflowHasShortcutInputVariables": True,
        "WFWorkflowInputContentItemClasses": [
            "WFGenericFileContentItem", "WFImageContentItem", "WFAVAssetContentItem",
            "WFPDFContentItem", "WFStringContentItem", "WFRichTextContentItem",
            "WFURLContentItem", "WFSafariWebPageContentItem", "WFPhotoMediaContentItem",
        ],
        "WFWorkflowOutputContentItemClasses": [],
        "WFWorkflowNoInputBehavior": {
            "Name": "WFWorkflowNoInputBehaviorGetClipboard", "Parameters": {}},
        "WFWorkflowImportQuestions": [{
            "ActionIndex": 0,
            "Category": "Parameter",
            "ParameterKey": "WFTextActionText",
            "Text": "plop's address: keep plop.local, or type the number the web shelf shows (192.168.…:7567)",
            "DefaultValue": "plop.local:7567",
        }],
        "WFWorkflowActions": actions,
    }


if __name__ == "__main__":
    dest = sys.argv[1]
    with tempfile.TemporaryDirectory() as d:
        raw = os.path.join(d, "Send to plop.shortcut")
        with open(raw, "wb") as f:
            plistlib.dump(build(), f, fmt=plistlib.FMT_BINARY)
        signed = os.path.join(d, "signed.shortcut")
        subprocess.run(["shortcuts", "sign", "--mode", "anyone",
                        "--input", raw, "--output", signed], check=True)
        data = open(signed, "rb").read()
    if dest.endswith(".shortcut"):
        open(dest, "wb").write(data)
    else:
        lines = textwrap.wrap(base64.b64encode(data).decode(), 76)
        with open(dest, "w") as f:
            f.write("// Generated by packaging/shortcut/make.py: the signed\n"
                    "// \"Send to plop\" Shortcut the web shelf serves.\n\n"
                    "const sendToPlopShortcut =\n")
            f.write("\n".join("    '%s'" % l for l in lines) + ";\n")
