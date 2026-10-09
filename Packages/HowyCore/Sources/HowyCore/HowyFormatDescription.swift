import Foundation

extension HowyFormat {
    /// A complete, valid `howy.json`: one open todo with an attachment, one done todo. Part of
    /// `llmDescription`; a test imports it so the description can't drift from the code.
    public static let llmExample = """
    {
      "formatVersion": 1,
      "todos": [
        {
          "id": "6F1C2A4E-8B1D-4C55-9E0B-2D7F3A1B9C10",
          "title": "Prepare tax documents",
          "note": "Collect all receipts.\\n\\n![receipt](receipt.png)",
          "quadrant": "urgent-important",
          "createdAt": "2026-10-01T08:00:00Z",
          "sortDate": "2026-10-01T08:00:00Z",
          "completedAt": null,
          "attachments": [
            { "id": "0A9B8C7D-6E5F-4A3B-9C1D-0E9F8A7B6C5D", "name": "receipt.png" }
          ]
        },
        {
          "id": "3D2E1F0A-9B8C-4D7E-8F6A-5B4C3D2E1F0A",
          "title": "Book dentist appointment",
          "quadrant": "not-urgent-important",
          "createdAt": "2026-09-20T10:15:00Z",
          "completedAt": "2026-09-22T17:30:00Z"
        }
      ]
    }
    """

    /// Text for "Copy for AI" (Settings → Import Format): a prompt that has an LLM convert any
    /// list of tasks into Howy's import format.
    public static let llmDescription = """
    Convert the following data into this Howy import format. Output only howy.json.

    # Howy import format (formatVersion 1)

    howy.json is a JSON object:
    - "formatVersion": required, always 1.
    - "todos": required, a list of todo objects.
    - "appVersion", "exportedAt": optional, for information only.

    Each todo object:
    - "id": required. A UUID (e.g. "6F1C2A4E-8B1D-4C55-9E0B-2D7F3A1B9C10"). Make up a new random UUID for every todo.
    - "title": required, not empty. Plain text, one line.
    - "quadrant": required, one of the four values below.
    - "createdAt": required. When the todo was created.
    - "note": optional, default "". Markdown text for details.
    - "sortDate": optional, defaults to createdAt. Newer sortDates are listed first within a quadrant.
    - "completedAt": optional, default null. null means open; a date means done (archived).
    - "attachments": optional, default []. Each attachment is { "id": UUID, "name": file name }. Names must be plain file names, unique within the todo, without "/", "\\" or "..". To show an image in the note, reference it as ![label](name); other files as [name](name).

    All dates are ISO 8601 in UTC with a "Z", e.g. "2026-10-01T08:00:00Z". Unknown keys are ignored.

    Quadrant values (Eisenhower matrix):
    - "urgent-important": Do. Urgent and important.
    - "not-urgent-important": Plan. Important, not urgent.
    - "urgent-unimportant": Delegate. Urgent, not important.
    - "not-urgent-unimportant": Drop. Neither urgent nor important.

    Example howy.json:

    ```json
    \(llmExample)
    ```

    Folder layout to import (choose the folder in Howy → Import…):

    ```
    My Import/
      howy.json
      attachments/
        <todo id>/
          <attachment name>
    ```

    For the example above, the image goes to attachments/6F1C2A4E-8B1D-4C55-9E0B-2D7F3A1B9C10/receipt.png. Todos without attachments need no folder.
    """
}
