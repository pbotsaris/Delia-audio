import os
from setuptools.command.build_ext import build_ext


class ZigBuilder(build_ext):
    def build_extension(self, ext):
        assert len(ext.sources) == 1

        if not os.path.exists(self.build_lib):
            os.makedirs(self.build_lib)
        mode = "Debug" if self.debug else "ReleaseFast"

        # python.zig imports the `dsp` module, which imports `common`. Outside `zig build`
        # the modules are declared on the command line: `--dep` entries belong to the next
        # `-M<name>=<root file>`. Keep this in step with the module table in build.zig.
        src = os.path.dirname(ext.sources[0])
        modules = [
            "--dep", "dsp",
            f"-Mroot={ext.sources[0]}",
            "--dep", "common",
            f"-Mdsp={os.path.join(src, 'dsp', 'dsp.zig')}",
            f"-Mcommon={os.path.join(src, 'common', 'root.zig')}",
        ]

        self.spawn(
            [
                "zig",
                "build-lib",
                "-O",
                mode,
                "-lc",
                f"-femit-bin={self.get_ext_fullpath(ext.name)}",
                "-fallow-shlib-undefined",
                "-dynamic",
                *[f"-I{d}" for d in self.include_dirs],
                *modules,
            ]
        )
