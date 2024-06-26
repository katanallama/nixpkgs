{
  lib,
  buildPythonPackage,
  datetime,
  fetchPypi,
  nvdlib,
  pydantic,
  pythonOlder,
  setuptools,
  typing-extensions,
}:

buildPythonPackage rec {
  pname = "avidtools";
  version = "0.1.2";
  pyproject = true;

  disabled = pythonOlder "3.9";

  src = fetchPypi {
    inherit pname version;
    hash = "sha256-2YtX+kUryTwaQ4QvExw5OJ4Rx8JoTzBeC8VSyNEL7OY=";
  };

  postPatch = ''
    sed -i "/'typing'/d" setup.py
  '';

  nativeBuildInputs = [ setuptools ];

  propagatedBuildInputs = [
    datetime
    nvdlib
    pydantic
    typing-extensions
  ];

  # Module has no tests
  doCheck = false;

  pythonImportsCheck = [ "avidtools" ];

  meta = with lib; {
    description = "Developer tools for AVID";
    homepage = "https://github.com/avidml/avidtools";
    license = licenses.asl20;
    maintainers = with maintainers; [ fab ];
  };
}
