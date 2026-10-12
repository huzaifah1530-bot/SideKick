from pathlib import Path
import ast, subprocess, tempfile, shutil, types, os
root=Path(__file__).resolve().parents[1]
bash=Path('C:/Program Files/Git/bin/bash.exe') if os.name == 'nt' else Path(shutil.which('bash') or '/bin/bash')
workflow=root/'Vendor/SideStore/scripts/ci/workflow.py'
source=workflow.read_text(encoding='utf-8'); tree=ast.parse(source)
helpers=ast.Module(body=[n for n in tree.body if isinstance(n,ast.FunctionDef) and n.name in ('run','runAndGet')], type_ignores=[])
class ShellProxy:
 PIPE=subprocess.PIPE
 def run(self,args,**kwargs):
  assert isinstance(args,list) and args[:4]==['/bin/bash','-o','pipefail','-c'], args
  return subprocess.run([str(bash),*args[1:]], **kwargs)
with tempfile.TemporaryDirectory(prefix='sidekick-vp-check-') as scratch:
 env={'subprocess':ShellProxy(),'ROOT':Path(scratch),'sys':__import__('sys')}
 exec(compile(helpers,str(workflow),'exec'),env)
 for fn in ('run','runAndGet'):
  try: env[fn]('printf pipeline-failure; exit 43 | cat')
  except subprocess.CalledProcessError as e: assert e.returncode==43
  else: raise AssertionError(fn+' swallowed failure')
  try: env[fn]('(printf pipeline-failure; exit 43) | tee preserved.log | cat')
  except subprocess.CalledProcessError as e: assert e.returncode==43
  else: raise AssertionError(fn+' swallowed pipeline failure')
  assert (Path(scratch)/'preserved.log').read_text()=='pipeline-failure'
 print('VP-013: both actual wrapper helpers reject pipeline failure and preserve tee log')
 helper=root/'Vendor/SideStore/Dependencies/SideSign/build.sh'
 target=Path(scratch)/'build.sh'; target.write_bytes(helper.read_text(encoding='utf-8').encode('utf-8'))
 result=subprocess.run([str(bash),'-c','swift() { return 47; }; export -f swift; bash build.sh'],cwd=scratch,capture_output=True,text=True)
 assert result.returncode==47,(result.returncode,result.stdout,result.stderr)
 log=(Path(scratch)/'build.log').read_text(); assert 'Build Complete!' not in log and 'Building SideSign' in log,log
 print('VP-038: copied build.sh returns failing Swift status 47 and retains log')
 for file in [helper, root/'Vendor/SideStore/Dependencies/SideSign/sample-usages.sh']:
  syntax=Path(scratch)/('syntax-'+file.name)
  syntax.write_bytes(file.read_text(encoding='utf-8').encode('utf-8'))
  result=subprocess.run([str(bash),'-n',str(syntax)],capture_output=True,text=True)
  assert result.returncode==0,result.stderr
 print('VP-038/039: Bash syntax checks passed (examples not executed)')
compile(source,str(workflow),'exec'); print('VP-013: Python syntax compile passed')
