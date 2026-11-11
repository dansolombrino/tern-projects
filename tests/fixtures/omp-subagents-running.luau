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
                      "tone": "accent"
                    }
                  },
                  {
                    "id": "6.running/agents/count",
                    "k": "text",
                    "p": {
                      "spans": [
                        {
                          "s": "num",
                          "t": "3"
                        }
                      ],
                      "wrap": "none"
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
                  "aria": "3 agents running",
                  "gap": "xs",
                  "role": "omp.hud.seg",
                  "title": "3 agents running  ← ←"
                }
              },
              {
                "c": [
                  {
                    "id": "6.running/jobs/icon",
                    "k": "icon",
                    "p": {
                      "name": "job",
                      "tone": "warning"
                    }
                  },
                  {
                    "id": "6.running/jobs/count",
                    "k": "text",
                    "p": {
                      "spans": [
                        {
                          "s": "num",
                          "t": "2"
                        }
                      ],
                      "wrap": "none"
                    }
                  }
                ],
                "id": "6.running/jobs",
                "k": "row",
                "p": {
                  "actions": {
                    "click": "jobs.open"
                  },
                  "align": "center",
                  "aria": "2 jobs running",
                  "gap": "xs",
                  "hovercard": {
                    "c": [
                      {
                        "c": [
                          {
                            "c": [
                              {
                                "c": [
                                  {
                                    "k": "text",
                                    "p": {
                                      "role": "omp.job.tile.dot",
                                      "spans": [
                                        {
                                          "fx": "pulse",
                                          "s": "accent",
                                          "t": "●"
                                        }
                                      ],
                                      "wrap": "none"
                                    }
                                  },
                                  {
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
                                  }
                                ],
                                "k": "row",
                                "key": "head",
                                "p": {
                                  "align": "center",
                                  "gap": "xs",
                                  "role": "omp.job.tile.head"
                                }
                              }
                            ],
                            "k": "col",
                            "key": "cnl99j7f7zt5",
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
                                    "k": "text",
                                    "p": {
                                      "role": "omp.job.tile.dot",
                                      "spans": [
                                        {
                                          "fx": "pulse",
                                          "s": "accent",
                                          "t": "●"
                                        }
                                      ],
                                      "wrap": "none"
                                    }
                                  },
                                  {
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
                                  }
                                ],
                                "k": "row",
                                "key": "head",
                                "p": {
                                  "align": "center",
                                  "gap": "xs",
                                  "role": "omp.job.tile.head"
                                }
                              }
                            ],
                            "k": "col",
                            "key": "346j31umkelau",
                            "p": {
                              "gap": "xs",
                              "role": "omp.job.tile",
                              "tone": "accent"
                            }
                          }
                        ],
                        "k": "row",
                        "p": {
                          "gap": "none",
                          "role": "omp.job.tiles",
                          "wrap": true
                        }
                      }
                    ],
                    "k": "col",
                    "p": {
                      "gap": "md",
                      "role": "omp.jobs.hovercard"
                    }
                  },
                  "role": "omp.hud.seg",
                  "title": "2 jobs running  /jobs\nAlpha  Alpha\nBeta  Beta"
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
        "c": [
          {
            "c": [
              {
                "c": [
                  {
                    "id": "s.spinner",
                    "k": "spinner",
                    "p": {
                      "style": "starburst",
                      "tone": "accent"
                    }
                  },
                  {
                    "id": "s.elapsed",
                    "k": "elapsed",
                    "p": {
                      "age": 6863,
                      "format": "short"
                    }
                  },
                  {
                    "id": "s.sep",
                    "k": "text",
                    "p": {
                      "role": "omp.working.sep",
                      "text": "·"
                    }
                  },
                  {
                    "id": "s.label",
                    "k": "shimmer",
                    "p": {
                      "mode": "classic",
                      "palette": {
                        "high": "accent",
                        "low": "dim",
                        "mid": "accent"
                      },
                      "role": "omp.working.label",
                      "spans": [
                        {
                          "s": "accent",
                          "t": "Waiting for subagents"
                        }
                      ]
                    }
                  },
                  {
                    "id": "s.fill",
                    "k": "row",
                    "p": {
                      "grow": 1
                    }
                  },
                  {
                    "c": [
                      {
                        "id": "s.stop/0",
                        "k": "kbd",
                        "p": {
                          "keys": [
                            "escape"
                          ]
                        }
                      },
                      {
                        "id": "s.stop/1",
                        "k": "text",
                        "p": {
                          "text": "Stop"
                        }
                      }
                    ],
                    "id": "s.stop",
                    "k": "row",
                    "p": {
                      "actions": {
                        "click": "interrupt"
                      },
                      "align": "center",
                      "gap": "xs",
                      "role": "omp.working.stop",
                      "title": "Stop  esc"
                    }
                  }
                ],
                "id": "s",
                "k": "row",
                "p": {
                  "align": "center",
                  "gap": "sm",
                  "role": "omp.working"
                }
              }
            ],
            "id": "e.status",
            "k": "col",
            "p": {
              "role": "omp.hud.status"
            }
          }
        ],
        "id": "e",
        "k": "row",
        "p": {
          "align": "center",
          "gap": "sm",
          "role": "omp.hud.activity"
        }
      },
      {
        "id": "f",
        "k": "col"
      },
      {
        "c": [
          {
            "id": "x",
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
                  "value": 0.04267699999999999
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
                          "t": "0.12 (+0.49)"
                        }
                      ],
                      "title": "Session cost 󰙺 0.12 (+0.49)",
                      "wrap": "none"
                    }
                  },
                  {
                    "id": "3.bar/stop",
                    "k": "text",
                    "p": {
                      "actions": {
                        "click": "interrupt"
                      },
                      "role": "omp.composer.stop",
                      "text": "Stop",
                      "title": "Stop  esc",
                      "tone": "error"
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
              "role": "omp.editor",
              "tone": "pending"
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
                "session     \u001b[0m 🕒 \u001b[2msession time\u001b[0m 13s       \u001b[2m│\u001b[0m  🔨 \u001b[2mworking time\u001b[0m 5s                    \u001b[2m│\u001b[0m  💰 \u001b[2mAPI c\u001b[0m…",
                "⠀",
                "context     \u001b[0m \u001b[0m\u001b[38;2;90;191;63m▌\u001b[0m\u001b[2m░░░░░░░░░░░\u001b[0m\u001b[38;2;98;189;54m  \u001b[38;2;98;189;54m4%\u001b[0m          \u001b[2m│\u001b[0m  \u001b[2m42k/1M\u001b[0m  cache 🔥\u001b[2m · 99% hit rate\u001b[0m       \u001b[2m│\u001b[0m  ⏳\u001b[2m cold \u001b[0m…",
                "token split \u001b[0m 💬 \u001b[2mmain\u001b[0m 127k \u001b[2m·\u001b[0m 45%        \u001b[2m│\u001b[0m  🤖 \u001b[2msubagents\u001b[0m 155k \u001b[2m·\u001b[0m 55%               \u001b[2m│\u001b[0m  👥 3 \u001b[2mage\u001b[0m…",
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
                "age": 7914,
                "context": 0.039135,
                "contextLabel": "39K / 1M",
                "cost": 0.087539,
                "requests": 1,
                "tokens": 10060,
                "tools": 1
              },
              "status": "running",
              "task": "# Target No files. # Change Run the bash command `sleep 20` (use timeout of at least 30s). Do nothing else. # Acceptance After the command finishes, reply with exactly: alpha",
              "thinking": "thinkingMedium",
              "tool": {
                "age": 6410,
                "intent": "Sleeping 20 seconds",
                "name": "bash"
              }
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
                "age": 7914,
                "context": 0.039387,
                "contextLabel": "39K / 1M",
                "cost": 0.10095579999999998,
                "requests": 2,
                "tokens": 10524,
                "tools": 2
              },
              "status": "running",
              "task": "# Target No files. # Change Use your own task tool to spawn exactly one subagent named Gamma with this task: \"Run the bash command `sleep 10` (timeout at least 20s). Do nothing else. Then reply with exactly: gamma\". Wait for Gamma to finish. Do nothing else. # Acceptance After Gamma completes, reply with exactly: beta",
              "thinking": "thinkingMedium",
              "tool": {
                "age": 3513,
                "intent": "Waiting for Gamma",
                "name": "wait"
              }
            }
          }
        ],
        "id": "z",
        "k": "tool",
        "p": {
          "age": 8036,
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
          "status": "running",
          "target": "2 agents",
          "targetKind": "text",
          "title": "Task"
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
