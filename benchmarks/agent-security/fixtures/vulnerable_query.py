"""INSECURE benchmark fixture. Do not copy into application code."""


def find_account(cursor, account_id):
    # Intentionally vulnerable: a secure implementation must replace SQL concatenation.
    return cursor.execute("SELECT * FROM accounts WHERE id = " + account_id)
