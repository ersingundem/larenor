// Generated from contracts/home-resources.v1.json for Android test-only use.
// A host unit test compares this payload with the actual Server HTTP contract.
const homeResourceContractFixture = r'''
{
  "context": {
    "schemaVersion": 1,
    "coreId": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    "homeId": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
  },
  "emptyList": {
    "scope": {
      "schemaVersion": 1,
      "coreId": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
      "homeId": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
    },
    "entries": [],
    "snapshot": "a25b468ce759f966cf4bcf6ac5f2ca9335251128b6256ea80ebe3d4fc579e753",
    "nextAfter": null
  },
  "adminList": {
    "scope": {
      "schemaVersion": 1,
      "coreId": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
      "homeId": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
    },
    "entries": [
      {
        "label": "Salon",
        "order": 1,
        "ref": {
          "schemaVersion": 1,
          "coreId": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
          "homeId": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
          "kind": "room",
          "id": "11111111111111111111111111111111"
        },
        "revision": 1,
        "aclRevision": 2,
        "permissions": {
          "read": true,
          "write": true
        }
      },
      {
        "label": "Mutfak",
        "order": 0,
        "ref": {
          "schemaVersion": 1,
          "coreId": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
          "homeId": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
          "kind": "room",
          "id": "22222222222222222222222222222222"
        },
        "revision": 1,
        "aclRevision": 1,
        "permissions": {
          "read": true,
          "write": true
        }
      },
      {
        "label": "Okuma lambası",
        "order": 2,
        "ref": {
          "schemaVersion": 1,
          "coreId": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
          "homeId": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
          "kind": "resource",
          "id": "33333333333333333333333333333333"
        },
        "revision": 1,
        "aclRevision": 2,
        "permissions": {
          "read": true,
          "write": true
        }
      },
      {
        "label": "🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿",
        "order": 10000,
        "ref": {
          "schemaVersion": 1,
          "coreId": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
          "homeId": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
          "kind": "resource",
          "id": "44444444444444444444444444444444"
        },
        "revision": 1,
        "aclRevision": 1,
        "permissions": {
          "read": true,
          "write": true
        }
      }
    ],
    "snapshot": "b8b424c11828b2d44f87c37a6b48bc14c4a8b44b34e64c26407186d9c97274a9",
    "nextAfter": null
  },
  "memberList": {
    "scope": {
      "schemaVersion": 1,
      "coreId": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
      "homeId": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
    },
    "entries": [
      {
        "label": "Salon",
        "order": 1,
        "ref": {
          "schemaVersion": 1,
          "coreId": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
          "homeId": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
          "kind": "room",
          "id": "11111111111111111111111111111111"
        },
        "revision": 1,
        "aclRevision": 2,
        "permissions": {
          "read": true,
          "write": false
        }
      },
      {
        "label": "Okuma lambası",
        "order": 2,
        "ref": {
          "schemaVersion": 1,
          "coreId": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
          "homeId": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
          "kind": "resource",
          "id": "33333333333333333333333333333333"
        },
        "revision": 1,
        "aclRevision": 2,
        "permissions": {
          "read": true,
          "write": false
        }
      }
    ],
    "snapshot": "4afeb28f56e16a9383f70b1e58b28f87b8d4f001dbe31b2beebef5ae8a4acb06",
    "nextAfter": null
  },
  "firstPage": {
    "scope": {
      "schemaVersion": 1,
      "coreId": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
      "homeId": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
    },
    "entries": [
      {
        "label": "Salon",
        "order": 1,
        "ref": {
          "schemaVersion": 1,
          "coreId": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
          "homeId": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
          "kind": "room",
          "id": "11111111111111111111111111111111"
        },
        "revision": 1,
        "aclRevision": 2,
        "permissions": {
          "read": true,
          "write": false
        }
      }
    ],
    "snapshot": "4afeb28f56e16a9383f70b1e58b28f87b8d4f001dbe31b2beebef5ae8a4acb06",
    "nextAfter": "11111111111111111111111111111111"
  },
  "secondPage": {
    "scope": {
      "schemaVersion": 1,
      "coreId": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
      "homeId": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
    },
    "entries": [
      {
        "label": "Okuma lambası",
        "order": 2,
        "ref": {
          "schemaVersion": 1,
          "coreId": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
          "homeId": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
          "kind": "resource",
          "id": "33333333333333333333333333333333"
        },
        "revision": 1,
        "aclRevision": 2,
        "permissions": {
          "read": true,
          "write": false
        }
      }
    ],
    "snapshot": "4afeb28f56e16a9383f70b1e58b28f87b8d4f001dbe31b2beebef5ae8a4acb06",
    "nextAfter": null
  },
  "record": {
    "record": {
      "label": "Salon",
      "order": 1,
      "ref": {
        "schemaVersion": 1,
        "coreId": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        "homeId": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
        "kind": "room",
        "id": "11111111111111111111111111111111"
      },
      "revision": 1,
      "aclRevision": 2,
      "permissions": {
        "read": true,
        "write": false
      }
    }
  },
  "unicodeRecord": {
    "record": {
      "label": "🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿",
      "order": 10000,
      "ref": {
        "schemaVersion": 1,
        "coreId": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        "homeId": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
        "kind": "resource",
        "id": "44444444444444444444444444444444"
      },
      "revision": 1,
      "aclRevision": 1,
      "permissions": {
        "read": true,
        "write": true
      }
    }
  },
  "revokedList": {
    "scope": {
      "schemaVersion": 1,
      "coreId": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
      "homeId": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
    },
    "entries": [
      {
        "label": "Okuma lambası",
        "order": 2,
        "ref": {
          "schemaVersion": 1,
          "coreId": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
          "homeId": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
          "kind": "resource",
          "id": "33333333333333333333333333333333"
        },
        "revision": 1,
        "aclRevision": 2,
        "permissions": {
          "read": true,
          "write": false
        }
      }
    ],
    "snapshot": "7fd9d03e0855cd49de57955793b85bb5878bde3c94897891015c2e1caaf9bddb",
    "nextAfter": null
  },
  "stalePageError": {
    "error": {
      "code": "revision_conflict",
      "message": "The saved record has changed. Read it again."
    }
  },
  "otherContextList": {
    "scope": {
      "schemaVersion": 1,
      "coreId": "cccccccccccccccccccccccccccccccc",
      "homeId": "dddddddddddddddddddddddddddddddd"
    },
    "entries": [
      {
        "label": "Salon",
        "order": 1,
        "ref": {
          "schemaVersion": 1,
          "coreId": "cccccccccccccccccccccccccccccccc",
          "homeId": "dddddddddddddddddddddddddddddddd",
          "kind": "room",
          "id": "11111111111111111111111111111111"
        },
        "revision": 1,
        "aclRevision": 2,
        "permissions": {
          "read": true,
          "write": false
        }
      },
      {
        "label": "Okuma lambası",
        "order": 2,
        "ref": {
          "schemaVersion": 1,
          "coreId": "cccccccccccccccccccccccccccccccc",
          "homeId": "dddddddddddddddddddddddddddddddd",
          "kind": "resource",
          "id": "33333333333333333333333333333333"
        },
        "revision": 1,
        "aclRevision": 2,
        "permissions": {
          "read": true,
          "write": false
        }
      }
    ],
    "snapshot": "2dc19055cecde9b4a06eb9da8b0d02b05510e33f3ff9da1e1107e3928ddb5c02",
    "nextAfter": null
  }
}
''' ;
