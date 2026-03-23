import Lake.Util.NativeLib

namespace RunAt.Lib

def pluginSharedLibName : String :=
  Lake.nameToSharedLib "runAt_RunAt"

def pluginSharedLibPath (dir : System.FilePath) : System.FilePath :=
  dir / pluginSharedLibName

end RunAt.Lib
