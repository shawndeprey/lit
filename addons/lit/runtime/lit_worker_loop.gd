extends SceneTree

## Main loop of a Lit shader worker process, launched with --script: the engine then
## loads the autoloads and no scene at all, and the LitManager autoload runs the bake.
## A scene path on the command line would do the same in the editor, but export
## templates reject one outright.
