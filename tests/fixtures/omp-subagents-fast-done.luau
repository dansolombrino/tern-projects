-- Real capture: cx.session:surface(pane, {as = "table"}) of an omp 18.18.8 agent block in Tern 0.9.16
-- (2026-11-11), encoded with tern.json.encode(tree, true). The JSON below is verbatim.
return [==[
{
  "dock": {
    "c": [
      {
        "c": [
          {
            "c": [
              {
                "c": [
                  {
                    "id": "6.running/agents/icon",
                    "k": "icon",
                    "p": {
                      "name": "users",
                      "tone": "muted"
                    }
                  }
                ],
                "id": "6.running/agents",
                "k": "row",
                "p": {
                  "actions": {
                    "click": "agents.open"
                  },
                  "align": "center",
                  "aria": "No agents running · 2 in this session",
                  "gap": "xs",
                  "role": "omp.hud.seg",
                  "title": "No agents running · 2 in this session  ← ←"
                }
              }
            ],
            "id": "6.running",
            "k": "row",
            "p": {
              "align": "center",
              "role": "omp.hud.pill"
            }
          }
        ],
        "id": "6",
        "k": "row",
        "p": {
          "justify": "end",
          "role": "omp.hud"
        }
      },
      {
        "id": "7",
        "k": "col"
      },
      {
        "id": "8",
        "k": "col"
      },
      {
        "id": "9",
        "k": "col"
      },
      {
        "id": "a",
        "k": "col"
      },
      {
        "id": "b",
        "k": "col"
      },
      {
        "id": "c",
        "k": "col"
      },
      {
        "c": [
          {
            "id": "k",
            "k": "col",
            "p": {
              "role": "omp.hud.judge"
            }
          },
          {
            "id": "l",
            "k": "col",
            "p": {
              "role": "omp.hud.downloads"
            }
          }
        ],
        "id": "d",
        "k": "col"
      },
      {
        "id": "e",
        "k": "col"
      },
      {
        "id": "f",
        "k": "col"
      },
      {
        "c": [
          {
            "id": "15",
            "k": "col"
          }
        ],
        "id": "g",
        "k": "col"
      },
      {
        "id": "h",
        "k": "col"
      },
      {
        "c": [
          {
            "c": [
              {
                "id": "3.context",
                "k": "meter",
                "p": {
                  "actions": {
                    "click": "status.context"
                  },
                  "label": "4%",
                  "marks": [
                    {
                      "at": 0.818,
                      "icon": "context.speculation",
                      "title": "Compaction summary starts at 82%"
                    },
                    {
                      "at": 0.85,
                      "icon": "context.compaction",
                      "title": "Auto-compact at 85%"
                    }
                  ],
                  "role": "omp.composer.context",
                  "style": "bar",
                  "thresholds": {
                    "bad": 0.5,
                    "warn": 0.15
                  },
                  "title": "Context 4% used\n44K of 1M tokens\nAuto-compact at 85%",
                  "total": "1M",
                  "value": 0.043631
                }
              },
              {
                "id": "n",
                "k": "row",
                "p": {
                  "gap": "sm",
                  "hidden": true,
                  "role": "omp.composer.chips",
                  "wrap": true
                }
              },
              {
                "c": [
                  {
                    "id": "3.line/input",
                    "k": "editor",
                    "p": {
                      "cursor": 0,
                      "maxLines": 18,
                      "placeholder": [
                        {
                          "s": "em",
                          "t": "“󰃻 PARA: Run two parallel subagents”"
                        }
                      ],
                      "sendable": true,
                      "text": ""
                    }
                  }
                ],
                "id": "3.line",
                "k": "row",
                "p": {
                  "align": "start",
                  "gap": "sm",
                  "role": "omp.composer.line"
                }
              },
              {
                "c": [
                  {
                    "c": [
                      {
                        "id": "3.bar/model/effort",
                        "k": "effort",
                        "p": {
                          "actions": {
                            "click": "thinking.cycle"
                          },
                          "level": "medium",
                          "role": "omp.composer.model.effort",
                          "title": "Thinking effort: medium  ⇧⇥"
                        }
                      },
                      {
                        "id": "3.bar/model/name",
                        "k": "text",
                        "p": {
                          "spans": [
                            {
                              "s": "accent",
                              "t": "Opus 5.5"
                            }
                          ],
                          "wrap": "none"
                        }
                      },
                      {
                        "id": "3.bar/model/chev",
                        "k": "icon",
                        "p": {
                          "name": "chev"
                        }
                      }
                    ],
                    "id": "3.bar/model",
                    "k": "row",
                    "p": {
                      "actions": {
                        "click": "status.model"
                      },
                      "align": "center",
                      "gap": "xs",
                      "role": "omp.composer.model",
                      "title": "Switch model  ⌥P"
                    }
                  },
                  {
                    "c": [
                      {
                        "id": "3.bar/extras/git",
                        "k": "seg",
                        "p": {
                          "actions": {
                            "click": "status.git"
                          },
                          "icon": "branch",
                          "priority": 1003,
                          "role": "omp.composer.fact",
                          "spans": [
                            {
                              "s": "statusLineGitClean",
                              "t": "main"
                            }
                          ]
                        }
                      }
                    ],
                    "id": "3.bar/extras",
                    "k": "status",
                    "p": {
                      "grow": 1,
                      "role": "omp.composer.extras",
                      "transparent": true
                    }
                  },
                  {
                    "id": "3.bar/usage",
                    "k": "text",
                    "p": {
                      "actions": {
                        "click": "status.cost"
                      },
                      "role": "omp.composer.usage",
                      "spans": [
                        {
                          "s": "icon",
                          "t": "󰙺"
                        },
                        {
                          "t": "0.19 (+0.17)"
                        }
                      ],
                      "title": "Session cost 󰙺 0.19 (+0.17)",
                      "wrap": "none"
                    }
                  },
                  {
                    "id": "3.bar/send",
                    "k": "kbd",
                    "p": {
                      "actions": {
                        "click": "submit"
                      },
                      "keys": [
                        "enter"
                      ],
                      "role": "omp.composer.send",
                      "title": "Send  ⏎"
                    }
                  }
                ],
                "id": "3.bar",
                "k": "row",
                "p": {
                  "align": "center",
                  "gap": "sm",
                  "role": "omp.composer.bar"
                }
              }
            ],
            "id": "3",
            "k": "col",
            "p": {
              "role": "omp.editor"
            }
          }
        ],
        "id": "i",
        "k": "col"
      },
      {
        "c": [
          {
            "id": "s",
            "k": "rows",
            "p": {
              "cols": 92,
              "lines": [
                "",
                "\u001b[2mcwd:\u001b[0m \u001b[01;34m/tmp/zz-test-probe-repo\u001b[0m \u001b[2m·\u001b[0m \u001b[2msession name:\u001b[0m \u001b[1m󰃻 PARA: Run two parallel subagents\u001b[0m",
                "⠀",
                "\u001b[36mOpus 5.5 1M\u001b[0m \u001b[2m·\u001b[0m 🧠 \u001b[33mmedium\u001b[0m",
                "⠀",
                "all time    \u001b[0m 🔢 \u001b[2mtotal tokens\u001b[0m 46.2B     \u001b[2m│\u001b[0m  \u001b[2min\u001b[0m 25.7M \u001b[2m·\u001b[0m \u001b[2mout\u001b[0m 220.8M \u001b[2m·\u001b[0m \u001b[2mcache\u001b[0m 45.9B   \u001b[2m│\u001b[0m  🌱 \u001b[2msince\u001b[0m…",
                "session     \u001b[0m 🕒 \u001b[2msession time\u001b[0m 13s       \u001b[2m│\u001b[0m  🔨 \u001b[2mworking time\u001b[0m 6s                    \u001b[2m│\u001b[0m  💰 \u001b[2mAPI c\u001b[0m…",
                "⠀",
                "context     \u001b[0m \u001b[0m\u001b[38;2;90;191;63m▌\u001b[0m\u001b[2m░░░░░░░░░░░\u001b[0m\u001b[38;2;98;189;54m  \u001b[38;2;98;189;54m4%\u001b[0m          \u001b[2m│\u001b[0m  \u001b[2m43k/1M\u001b[0m  cache 🔥\u001b[2m · 99% hit rate\u001b[0m       \u001b[2m│\u001b[0m  ⏳\u001b[2m cold \u001b[0m…",
                "token split \u001b[0m 💬 \u001b[2mmain\u001b[0m 169k \u001b[2m·\u001b[0m 68%        \u001b[2m│\u001b[0m  🤖 \u001b[2msubagents\u001b[0m 78k \u001b[2m·\u001b[0m 32%                \u001b[2m│\u001b[0m  👥 2 \u001b[2mage\u001b[0m…",
                "⠀",
                "weekly limit\u001b[0m \u001b[38;2;90;191;63m\u001b[48;2;105;187;44m▌\u001b[38;2;118;183;11m\u001b[48;2;128;179;1m▌\u001b[38;2;137;175;1m\u001b[48;2;145;171;1m▌\u001b[38;2;154;166;1m\u001b[48;2;160;162;1m▌\u001b[38;2;165;157;2m\u001b[48;2;170;153;1m▌\u001b[0m\u001b[38;2;175;148;2m▍\u001b[0m\u001b[2m░░░░░░\u001b[0m\u001b[38;2;177;145;1m  \u001b[2multra\u001b[0m \u001b[38;2;177;145;1m45%\u001b[0m  \u001b[2m·\u001b[0m \u001b[2mmax\u001b[0m \u001b[38;2;220;78;2m90%\u001b[0m  \u001b[2m·\u001b[0m \u001b[2mpro\u001b[0m \u001b[38;2;218;67;54m100%\u001b[0m                     \u001b[2m│\u001b[0m  ⏳\u001b[2m reset\u001b[0m…",
                "fable  limit\u001b[0m \u001b[0m\u001b[38;2;94;190;59m▊\u001b[0m\u001b[2m░░░░░░░░░░░\u001b[0m\u001b[38;2;105;187;44m  \u001b[2multra\u001b[0m \u001b[38;2;105;187;44m6%\u001b[0m   \u001b[2m·\u001b[0m \u001b[2mmax\u001b[0m \u001b[38;2;123;181;2m12%\u001b[0m  \u001b[2m·\u001b[0m \u001b[2mpro n/a\u001b[0m                      \u001b[2m│\u001b[0m  ⏳\u001b[2m reset\u001b[0m…",
                "⠀"
              ]
            }
          }
        ],
        "id": "j",
        "k": "col"
      }
    ],
    "id": "dock",
    "k": "col"
  },
  "layer": {
    "id": "layer",
    "k": "col"
  },
  "main": {
    "c": [
      {
        "id": "o",
        "k": "spacer",
        "p": {
          "size": "sm"
        }
      },
      {
        "c": [
          {
            "c": [
              {
                "id": "1.lockup/logo",
                "k": "image",
                "p": {
                  "alt": "omp",
                  "builtin": "omp",
                  "role": "omp.welcome.logo",
                  "w": 128
                }
              },
              {
                "c": [
                  {
                    "id": "1.lockup/mark/omp.welcome.wordmark",
                    "k": "text",
                    "p": {
                      "role": "omp.welcome.wordmark",
                      "spans": [
                        {
                          "s": "strong",
                          "t": "omp"
                        }
                      ],
                      "wrap": "none"
                    }
                  },
                  {
                    "id": "1.lockup/mark/omp.welcome.version",
                    "k": "text",
                    "p": {
                      "role": "omp.welcome.version",
                      "spans": [
                        {
                          "s": "dim mono",
                          "t": "v18.18.8"
                        }
                      ],
                      "wrap": "none"
                    }
                  }
                ],
                "id": "1.lockup/mark",
                "k": "col",
                "p": {
                  "role": "omp.welcome.mark"
                }
              }
            ],
            "id": "1.lockup",
            "k": "row",
            "p": {
              "align": "center",
              "gap": "md",
              "role": "omp.welcome.lockup"
            }
          },
          {
            "c": [
              {
                "id": "1.tip/0",
                "k": "icon",
                "p": {
                  "name": "lightbulb",
                  "role": "omp.welcome.tip-icon"
                }
              },
              {
                "id": "1.tip/1",
                "k": "text",
                "p": {
                  "role": "omp.welcome.tip-text",
                  "text": "`/copy code` grabs the last code block to your clipboard — `/copy cmd` grabs the last shell/python command",
                  "wrap": "word"
                }
              }
            ],
            "id": "1.tip",
            "k": "row",
            "p": {
              "align": "start",
              "gap": "sm",
              "role": "omp.welcome.tip"
            }
          }
        ],
        "id": "1",
        "k": "card",
        "p": {
          "role": "omp.welcome"
        }
      },
      {
        "id": "p",
        "k": "spacer",
        "p": {
          "size": "sm"
        }
      },
      {
        "c": [
          {
            "c": [
              {
                "id": "t.tools/copy",
                "k": "icon",
                "p": {
                  "actions": {
                    "click": "copy-message"
                  },
                  "aria": "Copy message",
                  "name": "copy",
                  "role": "omp.user.tool",
                  "title": "Copy message"
                }
              },
              {
                "id": "t.tools/rewind",
                "k": "icon",
                "p": {
                  "actions": {
                    "click": "rewind"
                  },
                  "aria": "Rewind",
                  "name": "rewind",
                  "role": "omp.user.tool",
                  "title": "Rewind the conversation to an earlier message"
                }
              },
              {
                "id": "t.tools/dot",
                "k": "text",
                "p": {
                  "text": "·"
                }
              },
              {
                "id": "t.tools/3",
                "k": "text",
                "p": {
                  "role": "omp.user.time",
                  "spans": [
                    {
                      "s": "dim mono",
                      "t": "09:23"
                    }
                  ],
                  "title": "11/11/2026, 09:23:10"
                }
              }
            ],
            "id": "t.tools",
            "k": "row",
            "p": {
              "align": "center",
              "gap": "xs",
              "role": "omp.user.tools"
            }
          },
          {
            "id": "t.1",
            "k": "md",
            "p": {
              "text": "Use your task tool to run exactly 2 subagents in parallel: subagent one replies with the single word alpha, subagent two replies with the single word beta. Do nothing else. Then reply done."
            }
          }
        ],
        "id": "t",
        "k": "card",
        "p": {
          "actions": {
            "hold": [
              {
                "icon": "copy",
                "id": "copy-message",
                "label": "Copy message"
              },
              {
                "detail": "To composer",
                "icon": "edit",
                "id": "edit-turn",
                "label": "Edit & resend"
              },
              {
                "icon": "refresh",
                "id": "retry-turn",
                "label": "Retry turn"
              },
              {
                "icon": "rewind",
                "id": "rewind-turn",
                "label": "Rewind to here…"
              },
              {
                "detail": "New session",
                "icon": "branch",
                "id": "fork-turn",
                "label": "Fork from here"
              }
            ]
          },
          "role": "omp.user",
          "tone": "user"
        }
      },
      {
        "id": "v",
        "k": "col",
        "p": {
          "hidden": true
        }
      },
      {
        "id": "x",
        "k": "col",
        "p": {
          "role": "omp.assistant"
        }
      },
      {
        "c": [
          {
            "id": "y.0",
            "k": "text",
            "p": {
              "lines": 2,
              "role": "omp.tool.context",
              "spans": [
                {
                  "s": "muted",
                  "t": "# Goal Reply with a single word only. No tools, no other output."
                }
              ],
              "wrap": "word"
            }
          },
          {
            "c": [
              {
                "id": "y.Alpha/0",
                "k": "md",
                "p": {
                  "role": "omp.task.assignment",
                  "text": "# Target\nNo files.\n# Change\nReply with exactly the single word: alpha\n# Acceptance\nOutput is exactly `alpha`."
                }
              }
            ],
            "id": "y.Alpha",
            "k": "agent",
            "p": {
              "agent": "task",
              "badges": [
                {
                  "text": "background"
                }
              ],
              "collapsed": true,
              "collapsible": true,
              "hovercard": {
                "k": "md",
                "p": {
                  "role": "omp.task.assignment",
                  "text": "# Target\nNo files.\n# Change\nReply with exactly the single word: alpha\n# Acceptance\nOutput is exactly `alpha`."
                }
              },
              "model": "anthropic/claude-opus-5-5",
              "name": "Alpha",
              "stats": {
                "context": 0.039004,
                "contextLabel": "39K / 1M",
                "cost": 0.085291,
                "requests": 1,
                "tokens": 9929,
                "took": 1290
              },
              "status": "done",
              "task": "# Target No files. # Change Reply with exactly the single word: alpha # Acceptance Output is exactly `alpha`.",
              "thinking": "thinkingMedium"
            }
          },
          {
            "c": [
              {
                "id": "y.Beta/0",
                "k": "md",
                "p": {
                  "role": "omp.task.assignment",
                  "text": "# Target\nNo files.\n# Change\nReply with exactly the single word: beta\n# Acceptance\nOutput is exactly `beta`."
                }
              }
            ],
            "id": "y.Beta",
            "k": "agent",
            "p": {
              "agent": "task",
              "badges": [
                {
                  "text": "background"
                }
              ],
              "collapsed": true,
              "collapsible": true,
              "hovercard": {
                "k": "md",
                "p": {
                  "role": "omp.task.assignment",
                  "text": "# Target\nNo files.\n# Change\nReply with exactly the single word: beta\n# Acceptance\nOutput is exactly `beta`."
                }
              },
              "model": "anthropic/claude-opus-5-5",
              "name": "Beta",
              "stats": {
                "context": 0.039001,
                "contextLabel": "39K / 1M",
                "cost": 0.085255,
                "requests": 1,
                "tokens": 9926,
                "took": 1304
              },
              "status": "done",
              "task": "# Target No files. # Change Reply with exactly the single word: beta # Acceptance Output is exactly `beta`.",
              "thinking": "thinkingMedium"
            }
          }
        ],
        "id": "y",
        "k": "tool",
        "p": {
          "badges": [
            {
              "text": "background"
            }
          ],
          "collapsed": true,
          "collapsible": true,
          "frame": "card",
          "intent": "Spawning two reply subagents",
          "key": "toolu_01BtcB7dzHBFqsJpQxYeReBM",
          "name": "task",
          "preview": "none",
          "role": "omp.tool.task",
          "status": "done",
          "target": "2 agents",
          "targetKind": "text",
          "title": "Task",
          "took": 1337
        }
      },
      {
        "c": [
          {
            "id": "z.0",
            "k": "text",
            "p": {
              "spans": [
                {
                  "s": "dim",
                  "t": "09:23 · Δ 5.5s · in 8.3K · out 289 · cache 33K · ttft 1.9s"
                }
              ]
            }
          },
          {
            "id": "z.1",
            "k": "text",
            "p": {
              "spans": [
                {
                  "s": "dim",
                  "t": " · "
                }
              ]
            }
          },
          {
            "id": "z.2",
            "k": "rate",
            "p": {
              "unit": "tok/s",
              "value": 72.2
            }
          }
        ],
        "id": "z",
        "k": "row",
        "p": {
          "align": "baseline",
          "gap": "none",
          "role": "omp.usage.turn",
          "title": "2026-11-11 09:23:11"
        }
      },
      {
        "id": "10",
        "k": "col",
        "p": {
          "role": "omp.assistant"
        }
      },
      {
        "c": [
          {
            "c": [
              {
                "c": [
                  {
                    "c": [
                      {
                        "id": "11.tiles/346j31umkelau/head/0",
                        "k": "text",
                        "p": {
                          "role": "omp.job.tile.dot",
                          "spans": [
                            {
                              "s": "success",
                              "t": "✓"
                            }
                          ],
                          "wrap": "none"
                        }
                      },
                      {
                        "id": "11.tiles/346j31umkelau/head/1",
                        "k": "text",
                        "p": {
                          "grow": 1,
                          "role": "omp.job.tile.title",
                          "spans": [
                            {
                              "t": "Beta"
                            }
                          ],
                          "truncate": "end",
                          "wrap": "none"
                        }
                      },
                      {
                        "id": "11.tiles/346j31umkelau/head/clock",
                        "k": "elapsed",
                        "p": {
                          "age": 1325,
                          "format": "short",
                          "stopped": 1325
                        }
                      }
                    ],
                    "id": "11.tiles/346j31umkelau/head",
                    "k": "row",
                    "p": {
                      "align": "center",
                      "gap": "xs",
                      "role": "omp.job.tile.head"
                    }
                  }
                ],
                "id": "11.tiles/346j31umkelau",
                "k": "col",
                "p": {
                  "gap": "xs",
                  "role": "omp.job.tile",
                  "tone": "success"
                }
              },
              {
                "c": [
                  {
                    "c": [
                      {
                        "id": "11.tiles/cnl99j7f7zt5/head/0",
                        "k": "text",
                        "p": {
                          "role": "omp.job.tile.dot",
                          "spans": [
                            {
                              "s": "success",
                              "t": "✓"
                            }
                          ],
                          "wrap": "none"
                        }
                      },
                      {
                        "id": "11.tiles/cnl99j7f7zt5/head/1",
                        "k": "text",
                        "p": {
                          "grow": 1,
                          "role": "omp.job.tile.title",
                          "spans": [
                            {
                              "t": "Alpha"
                            }
                          ],
                          "truncate": "end",
                          "wrap": "none"
                        }
                      },
                      {
                        "id": "11.tiles/cnl99j7f7zt5/head/clock",
                        "k": "elapsed",
                        "p": {
                          "age": 1320,
                          "format": "short",
                          "stopped": 1320
                        }
                      }
                    ],
                    "id": "11.tiles/cnl99j7f7zt5/head",
                    "k": "row",
                    "p": {
                      "align": "center",
                      "gap": "xs",
                      "role": "omp.job.tile.head"
                    }
                  }
                ],
                "id": "11.tiles/cnl99j7f7zt5",
                "k": "col",
                "p": {
                  "gap": "xs",
                  "role": "omp.job.tile",
                  "tone": "success"
                }
              }
            ],
            "id": "11.tiles",
            "k": "row",
            "p": {
              "gap": "none",
              "role": "omp.job.tiles",
              "wrap": true
            }
          }
        ],
        "id": "11",
        "k": "tool",
        "p": {
          "collapsed": true,
          "collapsible": true,
          "frame": "card",
          "intent": "Waiting for subagents",
          "key": "toolu_01DcusBLFcMBQbtxSq8G2F9b",
          "name": "wait",
          "preview": "children",
          "role": "omp.tool.wait",
          "status": "done",
          "title": [
            {
              "s": "toolTitle strong",
              "t": "2 jobs settled"
            },
            {
              "s": "success",
              "t": " 2 done"
            }
          ],
          "tone": "success",
          "took": 294
        }
      },
      {
        "c": [
          {
            "id": "12.0",
            "k": "text",
            "p": {
              "spans": [
                {
                  "s": "dim",
                  "t": "09:23 · Δ 6.6s · in 482 · out 54 · cache 42K · ttft 0.7s"
                }
              ]
            }
          },
          {
            "id": "12.1",
            "k": "text",
            "p": {
              "spans": [
                {
                  "s": "dim",
                  "t": " · "
                }
              ]
            }
          },
          {
            "id": "12.2",
            "k": "rate",
            "p": {
              "unit": "tok/s",
              "value": 52.9
            }
          }
        ],
        "id": "12",
        "k": "row",
        "p": {
          "align": "baseline",
          "gap": "none",
          "role": "omp.usage.turn",
          "title": "2026-11-11 09:23:15"
        }
      },
      {
        "c": [
          {
            "id": "13.t0",
            "k": "md",
            "p": {
              "text": "done"
            }
          },
          {
            "c": [
              {
                "id": "13.turn-usage/copy",
                "k": "icon",
                "p": {
                  "actions": {
                    "click": "copy-answer"
                  },
                  "aria": "Copy answer",
                  "name": "copy",
                  "role": "omp.turn.copy",
                  "title": "Copy answer"
                }
              },
              {
                "id": "13.turn-usage/dot",
                "k": "text",
                "p": {
                  "text": "·"
                }
              },
              {
                "id": "13.turn-usage/text",
                "k": "text",
                "p": {
                  "text": "7.9s · 9.4K tok · $0.10 this turn"
                }
              }
            ],
            "id": "13.turn-usage",
            "k": "row",
            "p": {
              "align": "center",
              "gap": "xs",
              "role": "omp.turn.usage",
              "title": "This turn: 7.9s · 9,450 tokens (9,104 in · 346 out) · $0.10"
            }
          }
        ],
        "id": "13",
        "k": "col",
        "p": {
          "actions": {
            "hold": [
              {
                "icon": "copy",
                "id": "copy-answer",
                "label": "Copy reply"
              },
              {
                "icon": "refresh",
                "id": "retry-turn",
                "label": "Retry turn"
              },
              {
                "icon": "rewind",
                "id": "rewind-turn",
                "label": "Rewind to here…"
              },
              {
                "detail": "New session",
                "icon": "branch",
                "id": "fork-turn",
                "label": "Fork from here"
              }
            ]
          },
          "role": "omp.assistant"
        }
      },
      {
        "c": [
          {
            "id": "14.0",
            "k": "text",
            "p": {
              "spans": [
                {
                  "s": "dim",
                  "t": "09:23 · Δ 7.9s · in 329 · out 3 · cache 42K · ttft 1.0s"
                }
              ]
            }
          },
          {
            "id": "14.1",
            "k": "text",
            "p": {
              "spans": [
                {
                  "s": "dim",
                  "t": " · "
                }
              ]
            }
          },
          {
            "id": "14.2",
            "k": "rate",
            "p": {
              "unit": "tok/s",
              "value": 2.9
            }
          }
        ],
        "id": "14",
        "k": "row",
        "p": {
          "align": "baseline",
          "gap": "none",
          "role": "omp.usage.turn",
          "title": "2026-11-11 09:23:16"
        }
      }
    ],
    "id": "main",
    "k": "col"
  },
  "surface": {
    "id": "s:1",
    "mode": "inline",
    "role": "omp.session",
    "title": "omp"
  }
}
]==]
