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
                  "aria": "No agents running · 3 in this session",
                  "gap": "xs",
                  "role": "omp.hud.seg",
                  "title": "No agents running · 3 in this session  ← ←"
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
            "id": "1c",
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
                  "title": "Context 4% used\n43K of 1M tokens\nAuto-compact at 85%",
                  "total": "1M",
                  "value": 0.043351
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
                          "t": "“󰒪 NEST: Run nested parallel sleep subagents”"
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
                          "t": "0.15 (+0.53)"
                        }
                      ],
                      "title": "Session cost 󰙺 0.15 (+0.53)",
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
            "id": "v",
            "k": "rows",
            "p": {
              "cols": 92,
              "lines": [
                "",
                "\u001b[2mcwd:\u001b[0m \u001b[01;34m/tmp/zz-test-probe-repo\u001b[0m \u001b[2m·\u001b[0m \u001b[2msession name:\u001b[0m \u001b[1m󰒪 NEST: Run nested parallel sleep subagents\u001b[0m",
                "⠀",
                "\u001b[36mOpus 5.5 1M\u001b[0m \u001b[2m·\u001b[0m 🧠 \u001b[33mmedium\u001b[0m",
                "⠀",
                "all time    \u001b[0m 🔢 \u001b[2mtotal tokens\u001b[0m 46.2B     \u001b[2m│\u001b[0m  \u001b[2min\u001b[0m 25.7M \u001b[2m·\u001b[0m \u001b[2mout\u001b[0m 220.8M \u001b[2m·\u001b[0m \u001b[2mcache\u001b[0m 45.9B   \u001b[2m│\u001b[0m  🌱 \u001b[2msince\u001b[0m…",
                "session     \u001b[0m 🕒 \u001b[2msession time\u001b[0m 34s       \u001b[2m│\u001b[0m  🔨 \u001b[2mworking time\u001b[0m 11s                   \u001b[2m│\u001b[0m  💰 \u001b[2mAPI c\u001b[0m…",
                "⠀",
                "context     \u001b[0m \u001b[0m\u001b[38;2;90;191;63m▌\u001b[0m\u001b[2m░░░░░░░░░░░\u001b[0m\u001b[38;2;98;189;54m  \u001b[38;2;98;189;54m4%\u001b[0m          \u001b[2m│\u001b[0m  \u001b[2m43k/1M\u001b[0m  cache 🔥\u001b[2m · 99% hit rate\u001b[0m       \u001b[2m│\u001b[0m  ⏳\u001b[2m cold \u001b[0m…",
                "token split \u001b[0m 💬 \u001b[2mmain\u001b[0m 257k \u001b[2m·\u001b[0m 45%        \u001b[2m│\u001b[0m  🤖 \u001b[2msubagents\u001b[0m 310k \u001b[2m·\u001b[0m 55%               \u001b[2m│\u001b[0m  👥 3 \u001b[2mage\u001b[0m…",
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
                  "text": "Find out which model you emotionally abuse the most with `omp stats`",
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
                "id": "r.tools/copy",
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
                "id": "r.tools/rewind",
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
                "id": "r.tools/dot",
                "k": "text",
                "p": {
                  "text": "·"
                }
              },
              {
                "id": "r.tools/3",
                "k": "text",
                "p": {
                  "role": "omp.user.time",
                  "spans": [
                    {
                      "s": "dim mono",
                      "t": "09:23"
                    }
                  ],
                  "title": "11/11/2026, 09:23:56"
                }
              }
            ],
            "id": "r.tools",
            "k": "row",
            "p": {
              "align": "center",
              "gap": "xs",
              "role": "omp.user.tools"
            }
          },
          {
            "id": "r.1",
            "k": "md",
            "p": {
              "text": "Use your task tool once to run exactly 2 subagents in parallel. Subagent Alpha: run the bash command `sleep 20`, then reply alpha. Subagent Beta: use your own task tool to spawn one subagent named Gamma that runs `sleep 10` in bash and replies gamma; then reply beta. Do nothing else. Then reply done."
            }
          }
        ],
        "id": "r",
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
        "id": "w",
        "k": "col",
        "p": {
          "hidden": true
        }
      },
      {
        "id": "y",
        "k": "col",
        "p": {
          "role": "omp.assistant"
        }
      },
      {
        "c": [
          {
            "id": "z.0",
            "k": "text",
            "p": {
              "lines": 2,
              "role": "omp.tool.context",
              "spans": [
                {
                  "s": "muted",
                  "t": "# Goal Simple orchestration probe. Do exactly what the task says, nothing else."
                }
              ],
              "wrap": "word"
            }
          },
          {
            "c": [
              {
                "id": "z.Beta/0",
                "k": "md",
                "p": {
                  "role": "omp.task.assignment",
                  "text": "# Target\nNo files.\n# Change\nUse your own task tool to spawn exactly one subagent named Gamma with this task: \"Run the bash command `sleep 10` (timeout at least 20s). Do nothing else. Then reply with exactly: gamma\". Wait for Gamma to finish. Do nothing else.\n# Acceptance\nAfter Gamma completes, reply with exactly: beta"
                }
              },
              {
                "c": [
                  {
                    "id": "z.Beta/Beta.Gamma/0",
                    "k": "md",
                    "p": {
                      "role": "omp.task.assignment",
                      "text": "Run the bash command `sleep 10` (timeout at least 20s). Do nothing else. Then reply with exactly: gamma"
                    }
                  }
                ],
                "id": "z.Beta/Beta.Gamma",
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
                  "depth": 1,
                  "hovercard": {
                    "k": "md",
                    "p": {
                      "role": "omp.task.assignment",
                      "text": "Run the bash command `sleep 10` (timeout at least 20s). Do nothing else. Then reply with exactly: gamma"
                    }
                  },
                  "name": "Beta>Gamma",
                  "stats": {
                    "took": 0
                  },
                  "status": "pending",
                  "task": "Run the bash command `sleep 10` (timeout at least 20s). Do nothing else. Then reply with exactly: gamma"
                }
              }
            ],
            "id": "z.Beta",
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
                  "text": "# Target\nNo files.\n# Change\nUse your own task tool to spawn exactly one subagent named Gamma with this task: \"Run the bash command `sleep 10` (timeout at least 20s). Do nothing else. Then reply with exactly: gamma\". Wait for Gamma to finish. Do nothing else.\n# Acceptance\nAfter Gamma completes, reply with exactly: beta"
                }
              },
              "model": "anthropic/claude-opus-5-5",
              "name": "Beta",
              "stats": {
                "context": 0.03971,
                "contextLabel": "40K / 1M",
                "cost": 0.12090559999999999,
                "requests": 4,
                "tokens": 10961,
                "took": 16897,
                "tools": 3
              },
              "status": "done",
              "task": "# Target No files. # Change Use your own task tool to spawn exactly one subagent named Gamma with this task: \"Run the bash command `sleep 10` (timeout at least 20s). Do nothing else. Then reply with exactly: gamma\". Wait for Gamma to finish. Do nothing else. # Acceptance After Gamma completes, reply with exactly: beta",
              "thinking": "thinkingMedium"
            }
          },
          {
            "c": [
              {
                "id": "z.Alpha/0",
                "k": "md",
                "p": {
                  "role": "omp.task.assignment",
                  "text": "# Target\nNo files.\n# Change\nRun the bash command `sleep 20` (use timeout of at least 30s). Do nothing else.\n# Acceptance\nAfter the command finishes, reply with exactly: alpha"
                }
              }
            ],
            "id": "z.Alpha",
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
                  "text": "# Target\nNo files.\n# Change\nRun the bash command `sleep 20` (use timeout of at least 30s). Do nothing else.\n# Acceptance\nAfter the command finishes, reply with exactly: alpha"
                }
              },
              "model": "anthropic/claude-opus-5-5",
              "name": "Alpha",
              "stats": {
                "context": 0.039169,
                "contextLabel": "39K / 1M",
                "cost": 0.0965402,
                "requests": 2,
                "tokens": 10203,
                "took": 23474,
                "tools": 1
              },
              "status": "done",
              "task": "# Target No files. # Change Run the bash command `sleep 20` (use timeout of at least 30s). Do nothing else. # Acceptance After the command finishes, reply with exactly: alpha",
              "thinking": "thinkingMedium"
            }
          }
        ],
        "id": "z",
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
          "intent": "Spawning Alpha and Beta subagents",
          "key": "toolu_01UQCyuWy1wSK1o27bkuUpBT",
          "name": "task",
          "preview": "none",
          "role": "omp.tool.task",
          "status": "done",
          "target": "2 agents",
          "targetKind": "text",
          "title": "Task",
          "took": 23513
        }
      },
      {
        "c": [
          {
            "id": "10.0",
            "k": "text",
            "p": {
              "spans": [
                {
                  "s": "dim",
                  "t": "09:23 · Δ 5.7s · in 9.3K · out 424 · cache 33K · ttft 1.1s"
                }
              ]
            }
          },
          {
            "id": "10.1",
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
            "id": "10.2",
            "k": "rate",
            "p": {
              "unit": "tok/s",
              "value": 99.4
            }
          }
        ],
        "id": "10",
        "k": "row",
        "p": {
          "align": "baseline",
          "gap": "none",
          "role": "omp.usage.turn",
          "title": "2026-11-11 09:23:58"
        }
      },
      {
        "id": "11",
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
                        "id": "12.tiles/cnl99j7f7zt5/head/0",
                        "k": "text",
                        "p": {
                          "role": "omp.job.tile.dot",
                          "spans": [
                            {
                              "s": "accent",
                              "t": "●"
                            }
                          ],
                          "wrap": "none"
                        }
                      },
                      {
                        "id": "12.tiles/cnl99j7f7zt5/head/1",
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
                        "id": "12.tiles/cnl99j7f7zt5/head/clock",
                        "k": "elapsed",
                        "p": {
                          "age": 6097,
                          "format": "short",
                          "stopped": 6097
                        }
                      }
                    ],
                    "id": "12.tiles/cnl99j7f7zt5/head",
                    "k": "row",
                    "p": {
                      "align": "center",
                      "gap": "xs",
                      "role": "omp.job.tile.head"
                    }
                  }
                ],
                "id": "12.tiles/cnl99j7f7zt5",
                "k": "col",
                "p": {
                  "gap": "xs",
                  "role": "omp.job.tile",
                  "tone": "accent"
                }
              },
              {
                "c": [
                  {
                    "c": [
                      {
                        "id": "12.tiles/346j31umkelau/head/0",
                        "k": "text",
                        "p": {
                          "role": "omp.job.tile.dot",
                          "spans": [
                            {
                              "s": "accent",
                              "t": "●"
                            }
                          ],
                          "wrap": "none"
                        }
                      },
                      {
                        "id": "12.tiles/346j31umkelau/head/1",
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
                        "id": "12.tiles/346j31umkelau/head/clock",
                        "k": "elapsed",
                        "p": {
                          "age": 6096,
                          "format": "short",
                          "stopped": 6096
                        }
                      }
                    ],
                    "id": "12.tiles/346j31umkelau/head",
                    "k": "row",
                    "p": {
                      "align": "center",
                      "gap": "xs",
                      "role": "omp.job.tile.head"
                    }
                  }
                ],
                "id": "12.tiles/346j31umkelau",
                "k": "col",
                "p": {
                  "gap": "xs",
                  "role": "omp.job.tile",
                  "tone": "accent"
                }
              }
            ],
            "id": "12.tiles",
            "k": "row",
            "p": {
              "gap": "none",
              "role": "omp.job.tiles",
              "wrap": true
            }
          }
        ],
        "id": "12",
        "k": "tool",
        "p": {
          "collapsed": true,
          "collapsible": true,
          "frame": "card",
          "intent": "Waiting for subagents",
          "key": "toolu_019AcRiry6tsRedDPwfVBKuG",
          "name": "wait",
          "preview": "children",
          "role": "omp.tool.wait",
          "status": "done",
          "title": [
            {
              "s": "toolTitle strong",
              "t": "waiting on 2 jobs"
            }
          ],
          "tone": "info",
          "took": 5007
        }
      },
      {
        "c": [
          {
            "id": "13.0",
            "k": "text",
            "p": {
              "spans": [
                {
                  "s": "dim",
                  "t": "09:24 · Δ 6.8s · in 617 · out 54 · cache 42K · ttft 0.8s"
                }
              ]
            }
          },
          {
            "id": "13.1",
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
            "id": "13.2",
            "k": "rate",
            "p": {
              "unit": "tok/s",
              "value": 50
            }
          }
        ],
        "id": "13",
        "k": "row",
        "p": {
          "align": "baseline",
          "gap": "none",
          "role": "omp.usage.turn",
          "title": "2026-11-11 09:24:02"
        }
      },
      {
        "id": "14",
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
                        "id": "15.tiles/cnl99j7f7zt5/head/0",
                        "k": "text",
                        "p": {
                          "role": "omp.job.tile.dot",
                          "spans": [
                            {
                              "s": "accent",
                              "t": "●"
                            }
                          ],
                          "wrap": "none"
                        }
                      },
                      {
                        "id": "15.tiles/cnl99j7f7zt5/head/1",
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
                        "id": "15.tiles/cnl99j7f7zt5/head/clock",
                        "k": "elapsed",
                        "p": {
                          "age": 18128,
                          "format": "short",
                          "stopped": 18128
                        }
                      }
                    ],
                    "id": "15.tiles/cnl99j7f7zt5/head",
                    "k": "row",
                    "p": {
                      "align": "center",
                      "gap": "xs",
                      "role": "omp.job.tile.head"
                    }
                  }
                ],
                "id": "15.tiles/cnl99j7f7zt5",
                "k": "col",
                "p": {
                  "gap": "xs",
                  "role": "omp.job.tile",
                  "tone": "accent"
                }
              },
              {
                "c": [
                  {
                    "c": [
                      {
                        "id": "15.tiles/346j31umkelau/head/0",
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
                        "id": "15.tiles/346j31umkelau/head/1",
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
                        "id": "15.tiles/346j31umkelau/head/clock",
                        "k": "elapsed",
                        "p": {
                          "age": 16929,
                          "format": "short",
                          "stopped": 16929
                        }
                      }
                    ],
                    "id": "15.tiles/346j31umkelau/head",
                    "k": "row",
                    "p": {
                      "align": "center",
                      "gap": "xs",
                      "role": "omp.job.tile.head"
                    }
                  }
                ],
                "id": "15.tiles/346j31umkelau",
                "k": "col",
                "p": {
                  "gap": "xs",
                  "role": "omp.job.tile",
                  "tone": "success"
                }
              }
            ],
            "id": "15.tiles",
            "k": "row",
            "p": {
              "gap": "none",
              "role": "omp.job.tiles",
              "wrap": true
            }
          }
        ],
        "id": "15",
        "k": "tool",
        "p": {
          "collapsed": true,
          "collapsible": true,
          "frame": "card",
          "intent": "Waiting for subagents",
          "key": "toolu_01LosBuvkQReutcnvxDnqkmK",
          "name": "wait",
          "preview": "children",
          "role": "omp.tool.wait",
          "status": "done",
          "title": [
            {
              "s": "toolTitle strong",
              "t": "waiting on 1 of 2 jobs"
            },
            {
              "s": "success",
              "t": " 1 done"
            }
          ],
          "tone": "info",
          "took": 10002
        }
      },
      {
        "c": [
          {
            "id": "16.0",
            "k": "text",
            "p": {
              "spans": [
                {
                  "s": "dim",
                  "t": "09:24 · Δ 13.9s · in 183 · out 54 · cache 43K · ttft 1.7s"
                }
              ]
            }
          },
          {
            "id": "16.1",
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
            "id": "16.2",
            "k": "rate",
            "p": {
              "unit": "tok/s",
              "value": 26.7
            }
          }
        ],
        "id": "16",
        "k": "row",
        "p": {
          "align": "baseline",
          "gap": "none",
          "role": "omp.usage.turn",
          "title": "2026-11-11 09:24:08"
        }
      },
      {
        "id": "17",
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
                        "id": "18.tiles/cnl99j7f7zt5/head/0",
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
                        "id": "18.tiles/cnl99j7f7zt5/head/1",
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
                        "id": "18.tiles/cnl99j7f7zt5/head/clock",
                        "k": "elapsed",
                        "p": {
                          "age": 23498,
                          "format": "short",
                          "stopped": 23498
                        }
                      }
                    ],
                    "id": "18.tiles/cnl99j7f7zt5/head",
                    "k": "row",
                    "p": {
                      "align": "center",
                      "gap": "xs",
                      "role": "omp.job.tile.head"
                    }
                  }
                ],
                "id": "18.tiles/cnl99j7f7zt5",
                "k": "col",
                "p": {
                  "gap": "xs",
                  "role": "omp.job.tile",
                  "tone": "success"
                }
              }
            ],
            "id": "18.tiles",
            "k": "row",
            "p": {
              "gap": "none",
              "role": "omp.job.tiles",
              "wrap": true
            }
          }
        ],
        "id": "18",
        "k": "tool",
        "p": {
          "collapsed": true,
          "collapsible": true,
          "frame": "card",
          "intent": "Waiting for Alpha",
          "key": "toolu_01CZ4zzpPbzfCBES1TNNhNJH",
          "name": "wait",
          "preview": "children",
          "role": "omp.tool.wait",
          "status": "done",
          "title": [
            {
              "s": "toolTitle strong",
              "t": "1 job settled"
            },
            {
              "s": "success",
              "t": " 1 done"
            }
          ],
          "tone": "success",
          "took": 2474
        }
      },
      {
        "c": [
          {
            "id": "19.0",
            "k": "text",
            "p": {
              "spans": [
                {
                  "s": "dim",
                  "t": "09:24 · Δ 26.8s · in 401 · out 70 · cache 43K · ttft 1.8s"
                }
              ]
            }
          },
          {
            "id": "19.1",
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
            "id": "19.2",
            "k": "rate",
            "p": {
              "unit": "tok/s",
              "value": 24.2
            }
          }
        ],
        "id": "19",
        "k": "row",
        "p": {
          "align": "baseline",
          "gap": "none",
          "role": "omp.usage.turn",
          "title": "2026-11-11 09:24:20"
        }
      },
      {
        "c": [
          {
            "id": "1a.t0",
            "k": "md",
            "p": {
              "text": "done\n\nBoth subagents finished: Alpha replied \"alpha\" after about 23.5s, and Beta replied \"beta\" after about 16.9s. I only saw Beta's reply, not Gamma's run, so I can't confirm from here that Gamma ran `sleep 10` and replied \"gamma\"."
            }
          },
          {
            "c": [
              {
                "id": "1a.turn-usage/copy",
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
                "id": "1a.turn-usage/dot",
                "k": "text",
                "p": {
                  "text": "·"
                }
              },
              {
                "id": "1a.turn-usage/text",
                "k": "text",
                "p": {
                  "text": "30.7s · 11K tok · $0.14 this turn"
                }
              }
            ],
            "id": "1a.turn-usage",
            "k": "row",
            "p": {
              "align": "center",
              "gap": "xs",
              "role": "omp.turn.usage",
              "title": "This turn: 30.7s · 11,409 tokens (10,708 in · 701 out) · $0.14"
            }
          }
        ],
        "id": "1a",
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
            "id": "1b.0",
            "k": "text",
            "p": {
              "spans": [
                {
                  "s": "dim",
                  "t": "09:24 · Δ 30.7s · in 218 · out 99 · cache 43K · ttft 1.5s"
                }
              ]
            }
          },
          {
            "id": "1b.1",
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
            "id": "1b.2",
            "k": "rate",
            "p": {
              "unit": "tok/s",
              "value": 67.3
            }
          }
        ],
        "id": "1b",
        "k": "row",
        "p": {
          "align": "baseline",
          "gap": "none",
          "role": "omp.usage.turn",
          "title": "2026-11-11 09:24:26"
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
