// Actual Server HTTP contract, embedded for Android test-only use.
// A host test compares every value with contracts/home-people.v1.json.
const homePeopleContractFixture = r'''
{
  "schemaVersion": 1,
  "context": {
    "schemaVersion": 1,
    "coreId": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    "homeId": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
  },
  "subjectId": "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee",
  "emptyList": {
    "method": "GET",
    "path": "/home-people/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
    "query": {},
    "body": null,
    "status": 200,
    "response": {
      "scope": {
        "schemaVersion": 1,
        "coreId": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        "homeId": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
      },
      "entries": [],
      "snapshot": "564b104b25d4652ee3cf890fea640fb794f896827660b7c16f257efb2eb971dc",
      "nextAfter": null
    }
  },
  "createPerson": {
    "method": "POST",
    "path": "/admin/home-people/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
    "query": {},
    "body": {
      "label": "Deniz Öztürk",
      "order": 7
    },
    "status": 201,
    "response": {
      "person": {
        "label": "Deniz Öztürk",
        "order": 7,
        "ref": {
          "schemaVersion": 1,
          "coreId": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
          "homeId": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
          "kind": "person",
          "id": "11111111111111111111111111111111"
        },
        "revision": 1,
        "aclRevision": 1,
        "permissions": {
          "read": true,
          "write": true
        }
      }
    }
  },
  "createUnicode": {
    "method": "POST",
    "path": "/admin/home-people/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
    "query": {},
    "body": {
      "label": "🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿",
      "order": 10000
    },
    "status": 201,
    "response": {
      "person": {
        "label": "🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿",
        "order": 10000,
        "ref": {
          "schemaVersion": 1,
          "coreId": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
          "homeId": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
          "kind": "person",
          "id": "22222222222222222222222222222222"
        },
        "revision": 1,
        "aclRevision": 1,
        "permissions": {
          "read": true,
          "write": true
        }
      }
    }
  },
  "emptyMember": {
    "method": "GET",
    "path": "/home-people/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
    "query": {},
    "body": null,
    "status": 200,
    "response": {
      "scope": {
        "schemaVersion": 1,
        "coreId": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        "homeId": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
      },
      "entries": [],
      "snapshot": "532b89c30b231764f7cbd8c0e8f5c9672fa83fe73fb40695bf7e27a57685255b",
      "nextAfter": null
    }
  },
  "emptyGrants": {
    "method": "GET",
    "path": "/admin/home-people/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb/11111111111111111111111111111111/grants",
    "query": {},
    "body": null,
    "status": 200,
    "response": {
      "aclRevision": 1,
      "grants": []
    }
  },
  "grantRead": {
    "method": "PUT",
    "path": "/admin/home-people/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb/11111111111111111111111111111111/grants/eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee",
    "query": {},
    "body": {
      "expectedAclRevision": 1,
      "permissions": {
        "read": true,
        "write": false
      }
    },
    "status": 200,
    "response": {
      "grant": {
        "subjectId": "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee",
        "target": {
          "schemaVersion": 1,
          "coreId": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
          "homeId": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
          "kind": "person",
          "id": "11111111111111111111111111111111"
        },
        "aclRevision": 2,
        "permissions": {
          "read": true,
          "write": false
        }
      }
    }
  },
  "grantUnicode": {
    "method": "PUT",
    "path": "/admin/home-people/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb/22222222222222222222222222222222/grants/eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee",
    "query": {},
    "body": {
      "expectedAclRevision": 1,
      "permissions": {
        "read": true,
        "write": false
      }
    },
    "status": 200,
    "response": {
      "grant": {
        "subjectId": "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee",
        "target": {
          "schemaVersion": 1,
          "coreId": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
          "homeId": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
          "kind": "person",
          "id": "22222222222222222222222222222222"
        },
        "aclRevision": 2,
        "permissions": {
          "read": true,
          "write": false
        }
      }
    }
  },
  "grantsAfterRead": {
    "method": "GET",
    "path": "/admin/home-people/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb/11111111111111111111111111111111/grants",
    "query": {},
    "body": null,
    "status": 200,
    "response": {
      "aclRevision": 2,
      "grants": [
        {
          "subjectId": "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee",
          "target": {
            "schemaVersion": 1,
            "coreId": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            "homeId": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
            "kind": "person",
            "id": "11111111111111111111111111111111"
          },
          "aclRevision": 2,
          "permissions": {
            "read": true,
            "write": false
          }
        }
      ]
    }
  },
  "memberRecord": {
    "method": "GET",
    "path": "/home-people/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb/11111111111111111111111111111111",
    "query": {},
    "body": null,
    "status": 200,
    "response": {
      "person": {
        "label": "Deniz Öztürk",
        "order": 7,
        "ref": {
          "schemaVersion": 1,
          "coreId": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
          "homeId": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
          "kind": "person",
          "id": "11111111111111111111111111111111"
        },
        "revision": 1,
        "aclRevision": 2,
        "permissions": {
          "read": true,
          "write": false
        }
      }
    }
  },
  "beforeUpdate": {
    "method": "GET",
    "path": "/home-people/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb/11111111111111111111111111111111",
    "query": {},
    "body": null,
    "status": 200,
    "response": {
      "person": {
        "label": "Deniz Öztürk",
        "order": 7,
        "ref": {
          "schemaVersion": 1,
          "coreId": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
          "homeId": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
          "kind": "person",
          "id": "11111111111111111111111111111111"
        },
        "revision": 1,
        "aclRevision": 2,
        "permissions": {
          "read": true,
          "write": true
        }
      }
    }
  },
  "adminList": {
    "method": "GET",
    "path": "/home-people/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
    "query": {},
    "body": null,
    "status": 200,
    "response": {
      "scope": {
        "schemaVersion": 1,
        "coreId": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        "homeId": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
      },
      "entries": [
        {
          "label": "Deniz Öztürk",
          "order": 7,
          "ref": {
            "schemaVersion": 1,
            "coreId": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            "homeId": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
            "kind": "person",
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
          "label": "🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿",
          "order": 10000,
          "ref": {
            "schemaVersion": 1,
            "coreId": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            "homeId": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
            "kind": "person",
            "id": "22222222222222222222222222222222"
          },
          "revision": 1,
          "aclRevision": 2,
          "permissions": {
            "read": true,
            "write": true
          }
        }
      ],
      "snapshot": "5a9b2e735a0c56a07737afb455ff0c4ad967e3ce722cd15d8fa7fa7098f077d6",
      "nextAfter": null
    }
  },
  "memberList": {
    "method": "GET",
    "path": "/home-people/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
    "query": {},
    "body": null,
    "status": 200,
    "response": {
      "scope": {
        "schemaVersion": 1,
        "coreId": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        "homeId": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
      },
      "entries": [
        {
          "label": "Deniz Öztürk",
          "order": 7,
          "ref": {
            "schemaVersion": 1,
            "coreId": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            "homeId": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
            "kind": "person",
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
          "label": "🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿",
          "order": 10000,
          "ref": {
            "schemaVersion": 1,
            "coreId": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            "homeId": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
            "kind": "person",
            "id": "22222222222222222222222222222222"
          },
          "revision": 1,
          "aclRevision": 2,
          "permissions": {
            "read": true,
            "write": false
          }
        }
      ],
      "snapshot": "f1f872c37f93086231198aa64af68354e60b99e4202af19b623913f208d82367",
      "nextAfter": null
    }
  },
  "firstPage": {
    "method": "GET",
    "path": "/home-people/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
    "query": {
      "limit": "1"
    },
    "body": null,
    "status": 200,
    "response": {
      "scope": {
        "schemaVersion": 1,
        "coreId": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        "homeId": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
      },
      "entries": [
        {
          "label": "Deniz Öztürk",
          "order": 7,
          "ref": {
            "schemaVersion": 1,
            "coreId": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            "homeId": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
            "kind": "person",
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
      "snapshot": "f1f872c37f93086231198aa64af68354e60b99e4202af19b623913f208d82367",
      "nextAfter": "11111111111111111111111111111111"
    }
  },
  "secondPage": {
    "method": "GET",
    "path": "/home-people/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
    "query": {
      "limit": "1",
      "after": "11111111111111111111111111111111",
      "expectedSnapshot": "f1f872c37f93086231198aa64af68354e60b99e4202af19b623913f208d82367"
    },
    "body": null,
    "status": 200,
    "response": {
      "scope": {
        "schemaVersion": 1,
        "coreId": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        "homeId": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
      },
      "entries": [
        {
          "label": "🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿",
          "order": 10000,
          "ref": {
            "schemaVersion": 1,
            "coreId": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            "homeId": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
            "kind": "person",
            "id": "22222222222222222222222222222222"
          },
          "revision": 1,
          "aclRevision": 2,
          "permissions": {
            "read": true,
            "write": false
          }
        }
      ],
      "snapshot": "f1f872c37f93086231198aa64af68354e60b99e4202af19b623913f208d82367",
      "nextAfter": null
    }
  },
  "updatePerson": {
    "method": "PATCH",
    "path": "/admin/home-people/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb/11111111111111111111111111111111",
    "query": {},
    "body": {
      "label": "Ece Öztürk",
      "order": 0,
      "expectedRevision": 1,
      "expectedAclRevision": 2
    },
    "status": 200,
    "response": {
      "person": {
        "label": "Ece Öztürk",
        "order": 0,
        "ref": {
          "schemaVersion": 1,
          "coreId": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
          "homeId": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
          "kind": "person",
          "id": "11111111111111111111111111111111"
        },
        "revision": 2,
        "aclRevision": 2,
        "permissions": {
          "read": true,
          "write": true
        }
      }
    }
  },
  "noopPerson": {
    "method": "PATCH",
    "path": "/admin/home-people/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb/11111111111111111111111111111111",
    "query": {},
    "body": {
      "label": "Ece Öztürk",
      "order": 0,
      "expectedRevision": 2,
      "expectedAclRevision": 2
    },
    "status": 200,
    "response": {
      "person": {
        "label": "Ece Öztürk",
        "order": 0,
        "ref": {
          "schemaVersion": 1,
          "coreId": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
          "homeId": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
          "kind": "person",
          "id": "11111111111111111111111111111111"
        },
        "revision": 2,
        "aclRevision": 2,
        "permissions": {
          "read": true,
          "write": true
        }
      }
    }
  },
  "grantWrite": {
    "method": "PUT",
    "path": "/admin/home-people/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb/11111111111111111111111111111111/grants/eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee",
    "query": {},
    "body": {
      "expectedAclRevision": 2,
      "permissions": {
        "read": true,
        "write": true
      }
    },
    "status": 200,
    "response": {
      "grant": {
        "subjectId": "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee",
        "target": {
          "schemaVersion": 1,
          "coreId": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
          "homeId": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
          "kind": "person",
          "id": "11111111111111111111111111111111"
        },
        "aclRevision": 3,
        "permissions": {
          "read": true,
          "write": true
        }
      }
    }
  },
  "grantNoop": {
    "method": "PUT",
    "path": "/admin/home-people/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb/11111111111111111111111111111111/grants/eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee",
    "query": {},
    "body": {
      "expectedAclRevision": 3,
      "permissions": {
        "read": true,
        "write": true
      }
    },
    "status": 200,
    "response": {
      "grant": {
        "subjectId": "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee",
        "target": {
          "schemaVersion": 1,
          "coreId": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
          "homeId": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
          "kind": "person",
          "id": "11111111111111111111111111111111"
        },
        "aclRevision": 3,
        "permissions": {
          "read": true,
          "write": true
        }
      }
    }
  },
  "staleMetadata": {
    "method": "PATCH",
    "path": "/admin/home-people/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb/11111111111111111111111111111111",
    "query": {},
    "body": {
      "label": "Ece Öztürk",
      "order": 0,
      "expectedRevision": 1,
      "expectedAclRevision": 2
    },
    "status": 409,
    "response": {
      "error": {
        "code": "revision_conflict",
        "message": "The saved record has changed. Read it again."
      }
    }
  },
  "memberCannotUpdate": {
    "method": "PATCH",
    "path": "/admin/home-people/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb/11111111111111111111111111111111",
    "query": {},
    "body": {
      "label": "Ece Öztürk",
      "order": 0,
      "expectedRevision": 2,
      "expectedAclRevision": 3
    },
    "status": 403,
    "response": {
      "error": {
        "code": "forbidden",
        "message": "This account cannot perform that action."
      }
    }
  },
  "revoke": {
    "method": "PUT",
    "path": "/admin/home-people/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb/11111111111111111111111111111111/grants/eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee",
    "query": {},
    "body": {
      "expectedAclRevision": 3,
      "permissions": {
        "read": false,
        "write": false
      }
    },
    "status": 200,
    "response": {
      "grant": {
        "subjectId": "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee",
        "target": {
          "schemaVersion": 1,
          "coreId": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
          "homeId": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
          "kind": "person",
          "id": "11111111111111111111111111111111"
        },
        "aclRevision": 4,
        "permissions": {
          "read": false,
          "write": false
        }
      }
    }
  },
  "afterRevoke": {
    "method": "GET",
    "path": "/admin/home-people/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb/11111111111111111111111111111111/grants",
    "query": {},
    "body": null,
    "status": 200,
    "response": {
      "aclRevision": 4,
      "grants": []
    }
  },
  "revokedRecord": {
    "method": "GET",
    "path": "/home-people/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb/11111111111111111111111111111111",
    "query": {},
    "body": null,
    "status": 404,
    "response": {
      "error": {
        "code": "not_found",
        "message": "The requested resource was not found."
      }
    }
  },
  "stalePage": {
    "method": "GET",
    "path": "/home-people/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
    "query": {
      "after": "11111111111111111111111111111111",
      "expectedSnapshot": "f1f872c37f93086231198aa64af68354e60b99e4202af19b623913f208d82367"
    },
    "body": null,
    "status": 409,
    "response": {
      "error": {
        "code": "revision_conflict",
        "message": "The saved record has changed. Read it again."
      }
    }
  },
  "beforeDelete": {
    "method": "GET",
    "path": "/home-people/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb/11111111111111111111111111111111",
    "query": {},
    "body": null,
    "status": 200,
    "response": {
      "person": {
        "label": "Ece Öztürk",
        "order": 0,
        "ref": {
          "schemaVersion": 1,
          "coreId": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
          "homeId": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
          "kind": "person",
          "id": "11111111111111111111111111111111"
        },
        "revision": 2,
        "aclRevision": 4,
        "permissions": {
          "read": true,
          "write": true
        }
      }
    }
  },
  "deletePerson": {
    "method": "DELETE",
    "path": "/admin/home-people/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb/11111111111111111111111111111111",
    "query": {
      "expectedRevision": "2",
      "expectedAclRevision": "4"
    },
    "body": null,
    "status": 204,
    "response": null
  },
  "deletedRecord": {
    "method": "GET",
    "path": "/home-people/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb/11111111111111111111111111111111",
    "query": {},
    "body": null,
    "status": 404,
    "response": {
      "error": {
        "code": "not_found",
        "message": "The requested resource was not found."
      }
    }
  },
  "foreignScope": {
    "method": "GET",
    "path": "/home-people/99999999999999999999999999999999/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
    "query": {},
    "body": null,
    "status": 404,
    "response": {
      "error": {
        "code": "not_found",
        "message": "The requested resource was not found."
      }
    }
  },
  "unknownCreateField": {
    "method": "POST",
    "path": "/admin/home-people/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
    "query": {},
    "body": {
      "label": "No account",
      "order": 0,
      "userId": "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"
    },
    "status": 400,
    "response": {
      "error": {
        "code": "invalid_request",
        "message": "The request is invalid."
      }
    }
  },
  "retiredAccount": {
    "method": "GET",
    "path": "/home-people/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
    "query": {},
    "body": null,
    "status": 401,
    "response": {
      "error": {
        "code": "invalid_session",
        "message": "Sign in again."
      }
    }
  },
  "otherContextList": {
    "method": "GET",
    "path": "/home-people/cccccccccccccccccccccccccccccccc/dddddddddddddddddddddddddddddddd",
    "query": {},
    "body": null,
    "status": 200,
    "response": {
      "scope": {
        "schemaVersion": 1,
        "coreId": "cccccccccccccccccccccccccccccccc",
        "homeId": "dddddddddddddddddddddddddddddddd"
      },
      "entries": [
        {
          "label": "İkinci ev · Deniz Öztürk",
          "order": 7,
          "ref": {
            "schemaVersion": 1,
            "coreId": "cccccccccccccccccccccccccccccccc",
            "homeId": "dddddddddddddddddddddddddddddddd",
            "kind": "person",
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
          "label": "🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿🌿",
          "order": 10000,
          "ref": {
            "schemaVersion": 1,
            "coreId": "cccccccccccccccccccccccccccccccc",
            "homeId": "dddddddddddddddddddddddddddddddd",
            "kind": "person",
            "id": "22222222222222222222222222222222"
          },
          "revision": 1,
          "aclRevision": 2,
          "permissions": {
            "read": true,
            "write": true
          }
        }
      ],
      "snapshot": "429b1c8e440abcb65be2cd772b3bb694c39a698b733d2f42581bb6b800d4a45d",
      "nextAfter": null
    }
  }
}
''' ;
